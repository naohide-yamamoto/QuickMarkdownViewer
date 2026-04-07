import AppKit
import CoreServices
import SwiftUI
import UniformTypeIdentifiers

/// Main content container for a document window.
///
/// This view switches among four states:
/// - empty
/// - loading
/// - failed
/// - loaded (web view)
struct DocumentWindowView: View {
    /// Observable state backing this document window.
    @ObservedObject var documentState: DocumentState

    /// Callback to open a file URL in QuickMarkdownViewer.
    let onOpenFile: (URL) -> Void

    /// Callback used by controls to launch the open panel.
    let onOpenAnotherFile: () -> Void

    /// Callback that forces app appearance to light mode.
    let onSetLightAppearance: () -> Void

    /// Callback that forces app appearance to dark mode.
    let onSetDarkAppearance: () -> Void

    /// True while a drag session hovers above this window.
    @State private var isDropTargeted = false

    /// Window number used to scope Find commands to this specific window.
    @State private var windowNumber: Int?

    /// Object identity of this SwiftUI view's host window.
    ///
    /// We use this as a stable fallback for command routing in exported builds
    /// where window-number propagation can lag briefly.
    @State private var hostWindowObjectID: ObjectIdentifier?

    /// Shared bridge used to run Find/Zoom operations inside `WKWebView`.
    @StateObject private var webViewSearchBridge = MarkdownWebViewSearchBridge()

    /// Native speech synthesiser scoped to this document window.
    @State private var speechSynthesizer = NSSpeechSynthesizer()

    /// Current Find query text.
    @State private var findQuery = ""

    /// True when Find should match case exactly.
    ///
    /// Default remains `false` so QuickMarkdownViewer keeps today's case-insensitive
    /// behaviour unless users explicitly enable match-case mode.
    @State private var isCaseSensitiveSearch = false

    /// True after at least one Find request has run for current query.
    @State private var hasAttemptedFind = false

    /// True when the last Find operation produced a match.
    @State private var didFindMatch = true

    /// True when the native search field currently owns keyboard focus.
    @State private var isFindFieldFocused = false

    /// True when the current phase has a loaded Markdown document.
    private var canUseDocumentControls: Bool {
        if case .loaded = documentState.phase, documentState.document != nil {
            return true
        }

        return false
    }

    /// True when app appearance is currently dark.
    private var isDarkAppearanceActive: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    var body: some View {
        ZStack {
            content

            if isDropTargeted {
                DragDropOverlayView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .onDrop(
            of: [UTType.fileURL.identifier],
            isTargeted: $isDropTargeted,
            perform: handleDrop(providers:)
        )
        .background(
            WindowNumberReader(
                windowNumber: $windowNumber,
                windowObjectID: $hostWindowObjectID
            )
        )
        .onReceive(
            NotificationCenter.default.publisher(for: .quickMarkdownViewerFindCommand),
            perform: handleFindNotification(_:)
        )
        .onReceive(
            NotificationCenter.default.publisher(for: .quickMarkdownViewerZoomCommand),
            perform: handleZoomNotification(_:)
        )
        .onReceive(
            NotificationCenter.default.publisher(for: .quickMarkdownViewerDocumentCommand),
            perform: handleDocumentNotification(_:)
        )
        .onExitCommand {
            // Escape should close active Find focus if present.
            guard isFindFieldFocused else { return }
            clearFindFieldFocus()
        }
        .onChange(of: isCaseSensitiveSearch) { _ in
            // Re-run search immediately when users toggle case mode so match
            // highlights always reflect the selected mode without extra steps.
            guard canUseDocumentControls else { return }
            runFind(direction: .forwards, shouldBeepOnNoMatch: false)
            publishFindStateChange()
        }
        .onChange(of: findQuery) { _ in
            publishFindStateChange()
        }
        .onChange(of: hostWindowObjectID) { _ in
            publishFindStateChange()
        }
    }

    /// Selects the correct visual state for the current document phase.
    @ViewBuilder
    private var content: some View {
        switch documentState.phase {
        case .empty:
            EmptyStateView(
                onOpenRequested: onOpenAnotherFile,
                onFileDropped: onOpenFile
            )

        case .loading:
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading Markdown…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

        case .failed(let message):
            VStack(spacing: 12) {
                Text("Couldn’t open this Markdown file.")
                    .font(.title3)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)

                Button("Open Another File…") {
                    onOpenAnotherFile()
                }
                .padding(.top, 6)
            }
            .padding(28)

        case .loaded:
            if let document = documentState.document {
                MarkdownWebView(
                    html: documentState.html,
                    baseURL: document.baseDirectoryURL,
                    documentURL: document.fileURL,
                    onOpenMarkdown: onOpenFile,
                    searchBridge: webViewSearchBridge
                )
            } else {
                Text("Couldn’t open this Markdown file.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Toolbar controls shown at all times.
    ///
    /// Layout intentionally mirrors utility viewers such as Preview:
    /// - quick Open button
    /// - grouped zoom controls
    /// - grouped light/dark controls
    /// - inline search field
    private var topControlBar: some View {
        HStack(spacing: 14) {
            OpenSegmentedControl(onOpenRequested: onOpenAnotherFile)
                .fixedSize()

            ZoomSegmentedControl(
                isEnabled: canUseDocumentControls,
                onZoomOut: zoomOutFromBar,
                onActualSize: resetZoomFromBar,
                onZoomIn: zoomInFromBar
            )
            .fixedSize()

            AppearanceSegmentedControl(
                isDarkAppearanceActive: isDarkAppearanceActive,
                onSetLightAppearance: onSetLightAppearance,
                onSetDarkAppearance: onSetDarkAppearance
            )
            .fixedSize()

            DocumentActionSegmentedControl(
                isEnabled: canUseDocumentControls,
                onPrint: printRenderedDocument,
                onExportPDF: exportRenderedPDF
            )
            .fixedSize()

            Spacer(minLength: 6)

            HStack(spacing: 6) {
                NativeSearchField(
                    text: $findQuery,
                    isCaseSensitive: $isCaseSensitiveSearch,
                    isEnabled: canUseDocumentControls,
                    isFocused: $isFindFieldFocused,
                    placeholder: "Search",
                    onSubmit: {
                        runFind(direction: .forwards, shouldBeepOnNoMatch: true)
                    },
                    onTextChanged: {
                        // Live find keeps interactions fast and lightweight.
                        guard canUseDocumentControls else { return }
                        runFind(direction: .forwards, shouldBeepOnNoMatch: false)
                    }
                )
                    .frame(minWidth: 180, idealWidth: 230, maxWidth: 280)

                if hasAttemptedFind && !didFindMatch && canUseDocumentControls {
                    Text("No matches")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 320, alignment: .trailing)
        }
        // Keep controls close to the leading edge while preserving
        // comfortable trailing space for the find field.
        .padding(.leading, 6)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    /// Processes dropped file URLs and opens supported Markdown files.
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let url = extractURL(from: item) else {
                return
            }

            DispatchQueue.main.async {
                onOpenFile(url.standardizedFileURL)
            }
        }

        return true
    }

    /// Extracts a URL from an item provider payload.
    private func extractURL(from item: NSSecureCoding?) -> URL? {
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }

        if let url = item as? URL {
            return url
        }

        if let string = item as? String {
            return URL(string: string)
        }

        return nil
    }

    /// Applies a Find command if this view owns the target window.
    private func handleFindNotification(_ notification: Notification) {
        guard let commandRaw = notification.userInfo?[QuickMarkdownViewerFindCommandUserInfoKey.command.rawValue] as? String,
              let command = QuickMarkdownViewerFindCommand(rawValue: commandRaw),
              shouldHandleNotification(notification) else {
            return
        }

        handleFindCommand(command, userInfo: notification.userInfo)
    }

    /// Applies a Zoom command if this view owns the target window.
    private func handleZoomNotification(_ notification: Notification) {
        guard let commandRaw = notification.userInfo?[QuickMarkdownViewerZoomCommandUserInfoKey.command.rawValue] as? String,
              let command = QuickMarkdownViewerZoomCommand(rawValue: commandRaw),
              shouldHandleNotification(notification) else {
            return
        }

        handleZoomCommand(command)
    }

    /// Applies a document command if this view owns the target window.
    private func handleDocumentNotification(_ notification: Notification) {
        guard let commandRaw =
                notification.userInfo?[QuickMarkdownViewerDocumentCommandUserInfoKey.command.rawValue] as? String,
              let command = QuickMarkdownViewerDocumentCommand(rawValue: commandRaw),
              shouldHandleNotification(notification) else {
            return
        }

        handleDocumentCommand(command)
    }

    /// Returns true when this view should handle a routed app command.
    ///
    /// Preferred targeting is by concrete `NSWindow` identity, passed as the
    /// notification object. Legacy window-number targeting is retained as a
    /// compatibility fallback for any older notifications.
    private func shouldHandleNotification(_ notification: Notification) -> Bool {
        if let targetWindow = notification.object as? NSWindow {
            guard let hostWindowObjectID else {
                return false
            }
            return ObjectIdentifier(targetWindow) == hostWindowObjectID
        }

        if let targetWindowNumber =
            notification.userInfo?[QuickMarkdownViewerDocumentCommandUserInfoKey.targetWindowNumber.rawValue] as? Int {
            return targetWindowNumber == windowNumber
        }

        if let targetWindowNumber =
            notification.userInfo?[QuickMarkdownViewerFindCommandUserInfoKey.targetWindowNumber.rawValue] as? Int {
            return targetWindowNumber == windowNumber
        }

        if let targetWindowNumber =
            notification.userInfo?[QuickMarkdownViewerZoomCommandUserInfoKey.targetWindowNumber.rawValue] as? Int {
            return targetWindowNumber == windowNumber
        }

        return false
    }

    /// Executes Find behaviour for this window.
    private func handleFindCommand(_ command: QuickMarkdownViewerFindCommand, userInfo: [AnyHashable: Any]?) {
        guard canUseDocumentControls else {
            NSSound.beep()
            return
        }

        switch command {
        case .findNext:
            focusFindField()
            runFind(direction: .forwards, shouldBeepOnNoMatch: true)

        case .findPrevious:
            focusFindField()
            runFind(direction: .backwards, shouldBeepOnNoMatch: true)

        case .useSelectionForFind:
            // Mirror macOS behaviour: capture selected text and place it into
            // the Find query, then immediately highlight matches.
            useSelectionForFind(shouldJump: false)

        case .jumpToSelection:
            // Prefer current selection when available; otherwise reuse existing
            // query to perform the same "jump to next match" behaviour users
            // expect from Cmd+J in document viewers/editors.
            jumpToSelection()

        case .hideFindBar:
            clearFindFieldFocus()
            hasAttemptedFind = false
            didFindMatch = true

        case .setFindQuery:
            let updatedQuery =
                userInfo?[QuickMarkdownViewerFindCommandUserInfoKey.query.rawValue] as? String ?? ""
            let updatedCaseSensitivity =
                userInfo?[QuickMarkdownViewerFindCommandUserInfoKey.isCaseSensitive.rawValue] as? Bool
            let shouldRunSearch =
                userInfo?[QuickMarkdownViewerFindCommandUserInfoKey.shouldRunSearch.rawValue] as? Bool ?? true
            let shouldBeep =
                userInfo?[QuickMarkdownViewerFindCommandUserInfoKey.shouldBeepOnNoMatch.rawValue] as? Bool ?? false

            findQuery = updatedQuery
            if let updatedCaseSensitivity {
                isCaseSensitiveSearch = updatedCaseSensitivity
            }

            if shouldRunSearch {
                runFind(direction: .forwards, shouldBeepOnNoMatch: shouldBeep)
            }

        case .setFindCaseSensitivity:
            guard let isCaseSensitive =
                userInfo?[QuickMarkdownViewerFindCommandUserInfoKey.isCaseSensitive.rawValue] as? Bool else {
                return
            }
            isCaseSensitiveSearch = isCaseSensitive
        }
    }

    /// Executes zoom behaviour for this window.
    private func handleZoomCommand(_ command: QuickMarkdownViewerZoomCommand) {
        guard canUseDocumentControls else {
            NSSound.beep()
            return
        }

        switch command {
        case .zoomIn:
            guard webViewSearchBridge.zoomIn() else {
                NSSound.beep()
                return
            }

        case .zoomOut:
            guard webViewSearchBridge.zoomOut() else {
                NSSound.beep()
                return
            }

        case .resetToActualSize:
            guard webViewSearchBridge.resetZoomToActualSize() else {
                NSSound.beep()
                return
            }

        case .zoomToFit:
            // Zoom-to-fit requires a DOM measurement, so result is delivered
            // asynchronously via callback.
            webViewSearchBridge.zoomToFitWidth { didHandle in
                guard !didHandle else { return }
                NSSound.beep()
            }
        }
    }

    /// Executes document-level actions for this window.
    ///
    /// These actions are routed from app-level menu commands and intentionally
    /// operate on the rendered web content (print/export) or source file URL
    /// (view source) for the active document window only.
    private func handleDocumentCommand(_ command: QuickMarkdownViewerDocumentCommand) {
        guard canUseDocumentControls else {
            NSSound.beep()
            return
        }

        switch command {
        case .printRenderedDocument:
            printRenderedDocument()

        case .exportRenderedPDF:
            exportRenderedPDF()

        case .viewSourceExternally:
            viewSourceExternally()

        case .startSpeaking:
            startSpeaking()

        case .stopSpeaking:
            stopSpeaking()
        }
    }

    /// Applies the toolbar zoom-out button action.
    private func zoomOutFromBar() {
        guard canUseDocumentControls else {
            NSSound.beep()
            return
        }

        guard webViewSearchBridge.zoomOut() else {
            NSSound.beep()
            return
        }
    }

    /// Applies the toolbar actual-size button action.
    private func resetZoomFromBar() {
        guard canUseDocumentControls else {
            NSSound.beep()
            return
        }

        guard webViewSearchBridge.resetZoomToActualSize() else {
            NSSound.beep()
            return
        }
    }

    /// Applies the toolbar zoom-in button action.
    private func zoomInFromBar() {
        guard canUseDocumentControls else {
            NSSound.beep()
            return
        }

        guard webViewSearchBridge.zoomIn() else {
            NSSound.beep()
            return
        }
    }

    /// Focuses the inline search field on the next run-loop tick.
    private func focusFindField() {
        DispatchQueue.main.async {
            isFindFieldFocused = true
        }
    }

    /// Clears keyboard focus from the inline search field.
    ///
    /// We explicitly resign first responder to keep Escape and "hide find"
    /// behaviour deterministic when using AppKit-backed controls.
    private func clearFindFieldFocus() {
        isFindFieldFocused = false
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    /// Runs a Find operation against rendered HTML in the web view.
    private func runFind(direction: MarkdownFindDirection, shouldBeepOnNoMatch: Bool) {
        let trimmedQuery = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedQuery.isEmpty else {
            hasAttemptedFind = false
            didFindMatch = true
            _ = webViewSearchBridge.clearFindHighlights()
            if shouldBeepOnNoMatch {
                NSSound.beep()
            }
            return
        }

        webViewSearchBridge.find(
            query: trimmedQuery,
            direction: direction,
            isCaseSensitive: isCaseSensitiveSearch
        ) { found in
            DispatchQueue.main.async {
                hasAttemptedFind = true
                didFindMatch = found

                if !found, shouldBeepOnNoMatch {
                    NSSound.beep()
                }
            }
        }
    }

    /// Prints the currently rendered Markdown document.
    ///
    /// This uses the web view print operation so output reflects rendered HTML
    /// styling, images, and layout rather than raw Markdown source text.
    private func printRenderedDocument() {
        guard webViewSearchBridge.printRenderedDocument(attachedTo: currentHostWindow()) else {
            NSSound.beep()
            return
        }
    }

    /// Exports the rendered Markdown document as a PDF file.
    ///
    /// The export destination is chosen through a standard save panel. User
    /// cancellation is treated as a normal path and does not beep.
    private func exportRenderedPDF() {
        let suggestedFilename: String
        if let sourceURL = documentState.document?.fileURL {
            let baseName = sourceURL.deletingPathExtension().lastPathComponent
            suggestedFilename = baseName.isEmpty ? "Quick Markdown Viewer Export.pdf" : "\(baseName).pdf"
        } else {
            suggestedFilename = "Quick Markdown Viewer Export.pdf"
        }

        webViewSearchBridge.exportRenderedPDF(
            attachedTo: currentHostWindow(),
            suggestedFilename: suggestedFilename
        ) { outcome in
            DispatchQueue.main.async {
                switch outcome {
                case .success, .cancelled:
                    break

                case .failed:
                    NSSound.beep()
                }
            }
        }
    }

    /// Speaks selected text when present, otherwise speaks the full document.
    private func startSpeaking() {
        guard canUseDocumentControls else {
            NSSound.beep()
            return
        }

        let fallbackMarkdown = documentState.document?.rawMarkdown ?? ""

        webViewSearchBridge.selectedText { selectedText in
            DispatchQueue.main.async {
                let trimmedSelection = selectedText?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let preferredText = (trimmedSelection?.isEmpty == false)
                    ? trimmedSelection!
                    : fallbackMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)

                guard !preferredText.isEmpty else {
                    NSSound.beep()
                    return
                }

                if speechSynthesizer.isSpeaking {
                    speechSynthesizer.stopSpeaking()
                }

                guard speechSynthesizer.startSpeaking(preferredText) else {
                    NSSound.beep()
                    return
                }
            }
        }
    }

    /// Stops current speech in this document window.
    private func stopSpeaking() {
        guard canUseDocumentControls else {
            NSSound.beep()
            return
        }

        speechSynthesizer.stopSpeaking()
    }

    /// Returns this document view's host window when available.
    ///
    /// Using the exact host window allows system panels (print/save) to appear
    /// as attached sheets rather than detached modal dialogs.
    private func currentHostWindow() -> NSWindow? {
        if let hostWindowObjectID,
           let hostWindow = NSApp.windows.first(where: { ObjectIdentifier($0) == hostWindowObjectID }) {
            return hostWindow
        }

        if let windowNumber,
           let targetWindow = NSApp.window(withWindowNumber: windowNumber) {
            return targetWindow
        }

        return NSApp.keyWindow ?? NSApp.mainWindow
    }

    /// Publishes current Find query + mode so toolbar/panel UI can stay in sync.
    private func publishFindStateChange() {
        guard let hostWindow = currentHostWindow() else {
            return
        }

        NotificationCenter.default.post(
            name: .quickMarkdownViewerFindStateDidChange,
            object: hostWindow,
            userInfo: [
                QuickMarkdownViewerFindCommandUserInfoKey.query.rawValue: findQuery,
                QuickMarkdownViewerFindCommandUserInfoKey.isCaseSensitive.rawValue: isCaseSensitiveSearch
            ]
        )
    }

    /// Opens the source Markdown file in the system's default plain-text editor.
    ///
    /// If no explicit plain-text editor can be resolved, we gracefully fall
    /// back to TextEdit and then to the system-default file open path.
    private func viewSourceExternally() {
        guard let sourceURL = documentState.document?.fileURL else {
            NSSound.beep()
            return
        }

        let workspace = NSWorkspace.shared
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        // Resolve the default handler for `public.plain-text` directly via
        // LaunchServices so behaviour matches system defaults (for example,
        // BBEdit when users set it as their preferred plain-text editor).
        let plainTextUTI = UTType.plainText.identifier as CFString
        if let defaultPlainTextBundleID =
            LSCopyDefaultRoleHandlerForContentType(plainTextUTI, .editor)?.takeRetainedValue() as String?,
           let plainTextEditorURL = workspace.urlForApplication(withBundleIdentifier: defaultPlainTextBundleID) {
            workspace.open([sourceURL], withApplicationAt: plainTextEditorURL, configuration: configuration) { _, error in
                if let error {
                    Logger.error("Opening source in default plain-text editor failed: \(error.localizedDescription)")
                    DispatchQueue.main.async {
                        NSSound.beep()
                    }
                }
            }
            return
        }

        if let textEditURL = workspace.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            workspace.open([sourceURL], withApplicationAt: textEditURL, configuration: configuration) { _, error in
                if let error {
                    Logger.error("Opening source in TextEdit failed: \(error.localizedDescription)")
                    DispatchQueue.main.async {
                        NSSound.beep()
                    }
                }
            }
            return
        }

        guard workspace.open(sourceURL) else {
            Logger.error("Opening source via system fallback failed for \(sourceURL.path)")
            NSSound.beep()
            return
        }
    }

    /// Uses current web selection as the active Find query.
    ///
    /// - Parameter shouldJump: when true, immediately advances/jumps to the
    ///   next active match (Cmd+J path). When false, just refreshes highlights.
    private func useSelectionForFind(shouldJump: Bool) {
        webViewSearchBridge.selectedText { selectedText in
            DispatchQueue.main.async {
                guard let selectedText else {
                    NSSound.beep()
                    return
                }

                findQuery = selectedText
                hasAttemptedFind = false
                didFindMatch = true

                if shouldJump {
                    runFind(direction: .forwards, shouldBeepOnNoMatch: true)
                } else {
                    runFind(direction: .forwards, shouldBeepOnNoMatch: false)
                }
            }
        }
    }

    /// Jumps to selection/query match using standard macOS fallback order.
    ///
    /// Priority:
    /// 1. If document text is selected, use that selection as Find query.
    /// 2. Otherwise, if a Find query already exists, jump to next match.
    /// 3. Otherwise, beep (nothing to jump to).
    private func jumpToSelection() {
        webViewSearchBridge.selectedText { selectedText in
            DispatchQueue.main.async {
                if let selectedText {
                    findQuery = selectedText
                    hasAttemptedFind = false
                    didFindMatch = true
                    runFind(direction: .forwards, shouldBeepOnNoMatch: true)
                    return
                }

                let trimmedQuery = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedQuery.isEmpty else {
                    NSSound.beep()
                    return
                }

                runFind(direction: .forwards, shouldBeepOnNoMatch: true)
            }
        }
    }
}

/// Native macOS search field wrapper used by the toolbar controls.
///
/// Using `NSSearchField` gives QuickMarkdownViewer the expected AppKit behaviour:
/// - familiar visual style
/// - proper macOS keyboard focus handling
/// - return-key submit action
/// - live text-change callbacks for incremental Find updates
private struct NativeSearchField: NSViewRepresentable {
    /// Search query text mirrored with SwiftUI state.
    @Binding var text: String

    /// True when Find should match case exactly.
    @Binding var isCaseSensitive: Bool

    /// True when the control should accept input.
    let isEnabled: Bool

    /// Two-way focus binding used by `Cmd+F` and Escape handling.
    @Binding var isFocused: Bool

    /// Placeholder text shown when query is empty.
    let placeholder: String

    /// Callback fired when user submits search (for example, Return key).
    let onSubmit: () -> Void

    /// Callback fired whenever query text changes.
    let onTextChanged: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.didSubmitSearch(_:))
        field.placeholderString = placeholder
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = true
        field.recentsAutosaveName = nil
        field.isEnabled = isEnabled
        context.coordinator.ensureSearchMenuAttached(to: field)
        return field
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        context.coordinator.parent = self

        // Mirror SwiftUI query text into the AppKit field only when the
        // binding value itself has changed since the last update cycle.
        // This avoids accidental overwrite during menu/focus refreshes.
        if text != context.coordinator.lastObservedBindingText {
            context.coordinator.lastObservedBindingText = text

            if nsView.stringValue != text {
                nsView.stringValue = text
            }
        }

        context.coordinator.ensureSearchMenuAttached(to: nsView)
        context.coordinator.syncSearchMenuCheckmarks()
        nsView.isEnabled = isEnabled

        let becameFocused = isFocused && !context.coordinator.wasFocused
        context.coordinator.wasFocused = isFocused

        if becameFocused, nsView.currentEditor() == nil {
            // Defer first-responder handoff to ensure the field is attached to
            // a window before focus is requested.
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }

    /// Delegate/target bridge between `NSSearchField` and SwiftUI bindings.
    final class Coordinator: NSObject, NSSearchFieldDelegate, NSMenuItemValidation, NSMenuDelegate {
        /// Tag used by the search menu item that enables case-insensitive mode.
        ///
        /// Values intentionally avoid the `1000...1003` range because AppKit
        /// reserves those tags for built-in search-recents menu placeholders.
        private static let caseInsensitiveMenuTag = 9101

        /// Tag used by the search menu item that enables case-sensitive mode.
        ///
        /// Values intentionally avoid the `1000...1003` range because AppKit
        /// reserves those tags for built-in search-recents menu placeholders.
        private static let caseSensitiveMenuTag = 9102

        /// Latest view configuration for callback access.
        var parent: NativeSearchField

        /// Weak reference to the search field used for menu attachment.
        private weak var searchField: NSSearchField?

        /// Stable menu template used by the search field magnifier button.
        ///
        /// Keeping one persistent instance avoids visual glitches that can
        /// happen when replacing `searchMenuTemplate` while editing text.
        private lazy var searchModeMenuTemplate: NSMenu = makeSearchModeMenu()

        /// Previous focus state used to detect focus transitions.
        var wasFocused = false

        /// True when the search field had focus before the magnifier menu opened.
        ///
        /// We use this flag to restore focus after the menu closes so users can
        /// continue typing, and to avoid a transient AppKit text-rendering quirk
        /// where the query can appear invisible immediately after focus loss.
        private var shouldRestoreFocusAfterMenuDismissal = false

        /// Last binding value observed by `updateNSView`.
        ///
        /// Tracking this lets us ignore refresh-only updates so the search
        /// field's visible text is not overwritten by stale state.
        var lastObservedBindingText: String

        init(parent: NativeSearchField) {
            self.parent = parent
            self.lastObservedBindingText = parent.text
        }

        /// Ensures the field has the persistent AppKit search-mode menu.
        ///
        /// The menu appears from the magnifying-glass icon and mirrors
        /// Preview-style subtle mode switching without extra chrome.
        func ensureSearchMenuAttached(to field: NSSearchField) {
            searchField = field
            let menuTemplate = searchModeMenuTemplate

            // Attach directly on `NSSearchField`, which is the current AppKit
            // API surface, so the magnifier button can present the menu. We do
            // not continuously replace this template after attachment.
            if field.searchMenuTemplate !== menuTemplate {
                field.searchMenuTemplate = menuTemplate
            }
        }

        /// Builds the two-mode search menu used by the magnifier dropdown.
        private func makeSearchModeMenu() -> NSMenu {
            let menu = NSMenu(title: "Search Mode")
            menu.delegate = self

            let caseInsensitiveItem = NSMenuItem(
                title: "Case Insensitive",
                action: #selector(selectCaseInsensitiveMode(_:)),
                keyEquivalent: ""
            )
            caseInsensitiveItem.tag = Self.caseInsensitiveMenuTag
            caseInsensitiveItem.target = self
            caseInsensitiveItem.state = .on
            menu.addItem(caseInsensitiveItem)

            let caseSensitiveItem = NSMenuItem(
                title: "Case Sensitive",
                action: #selector(selectCaseSensitiveMode(_:)),
                keyEquivalent: ""
            )
            caseSensitiveItem.tag = Self.caseSensitiveMenuTag
            caseSensitiveItem.target = self
            caseSensitiveItem.state = .off
            menu.addItem(caseSensitiveItem)

            syncSearchMenuCheckmarks(in: menu)
            return menu
        }

        /// Keeps the active search mode visibly ticked inside menu templates.
        func syncSearchMenuCheckmarks() {
            syncSearchMenuCheckmarks(in: searchModeMenuTemplate)
        }

        /// Applies menu checkmark state for current case-sensitivity mode.
        private func syncSearchMenuCheckmarks(in menu: NSMenu) {
            if let caseInsensitiveItem = menu.item(withTag: Self.caseInsensitiveMenuTag) {
                caseInsensitiveItem.state = parent.isCaseSensitive ? .off : .on
            }

            if let caseSensitiveItem = menu.item(withTag: Self.caseSensitiveMenuTag) {
                caseSensitiveItem.state = parent.isCaseSensitive ? .on : .off
            }
        }

        /// Switches Find to case-insensitive matching.
        @objc private func selectCaseInsensitiveMode(_ sender: NSMenuItem) {
            parent.isCaseSensitive = false
            if let presentedMenu = sender.menu {
                syncSearchMenuCheckmarks(in: presentedMenu)
            }
            syncSearchMenuCheckmarks()
        }

        /// Switches Find to case-sensitive matching.
        @objc private func selectCaseSensitiveMode(_ sender: NSMenuItem) {
            parent.isCaseSensitive = true
            if let presentedMenu = sender.menu {
                syncSearchMenuCheckmarks(in: presentedMenu)
            }
            syncSearchMenuCheckmarks()
        }

        /// Validates menu items and refreshes their checkmarks right before
        /// display, so the visible tick always matches the live mode state.
        func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
            switch menuItem.action {
            case #selector(selectCaseInsensitiveMode(_:)):
                menuItem.state = parent.isCaseSensitive ? .off : .on
                return parent.isEnabled

            case #selector(selectCaseSensitiveMode(_:)):
                menuItem.state = parent.isCaseSensitive ? .on : .off
                return parent.isEnabled

            default:
                return true
            }
        }

        /// Captures whether focus should be restored after menu dismissal.
        func menuWillOpen(_ menu: NSMenu) {
            shouldRestoreFocusAfterMenuDismissal = (searchField?.currentEditor() != nil) || parent.isFocused
        }

        /// Restores focus to the search field when appropriate.
        ///
        /// This preserves smooth "open menu then keep typing" behaviour and
        /// prevents the first-menu-open invisible-text rendering edge case.
        func menuDidClose(_ menu: NSMenu) {
            guard shouldRestoreFocusAfterMenuDismissal else {
                return
            }

            shouldRestoreFocusAfterMenuDismissal = false

            DispatchQueue.main.async { [weak self] in
                guard let self, let field = self.searchField else {
                    return
                }

                field.window?.makeFirstResponder(field)
                self.parent.isFocused = true
            }
        }

        /// Handles explicit submit actions (for example, pressing Return).
        @objc func didSubmitSearch(_ sender: NSSearchField) {
            if parent.text != sender.stringValue {
                parent.text = sender.stringValue
                lastObservedBindingText = sender.stringValue
            }
            parent.onSubmit()
        }

        /// Mirrors live typing into SwiftUI and triggers incremental Find.
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else {
                return
            }

            if parent.text != field.stringValue {
                parent.text = field.stringValue
                lastObservedBindingText = field.stringValue
            }

            parent.onTextChanged()
        }

        /// Tracks focus gain so menu commands can target this field reliably.
        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.isFocused = true
        }

        /// Tracks focus loss so Escape/menu logic stays in sync.
        func controlTextDidEndEditing(_ notification: Notification) {
            parent.isFocused = false
        }
    }
}

/// Native macOS segmented control for print and PDF export actions.
///
/// Keeping these actions in the same AppKit segmented style as the rest of the
/// toolbar preserves a consistent, Preview-like control surface.
private struct DocumentActionSegmentedControl: NSViewRepresentable {
    /// Controls whether document actions are currently available.
    let isEnabled: Bool

    /// Callback that prints the rendered document.
    let onPrint: () -> Void

    /// Callback that exports the rendered document as PDF.
    let onExportPDF: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.segmentCount = 2
        control.trackingMode = .momentary
        // Match the same grouped AppKit style used by the other toolbar controls.
        control.segmentStyle = .separated
        control.controlSize = .regular
        control.target = context.coordinator
        control.action = #selector(Coordinator.didActivateSegment(_:))

        // Segment 0: print rendered document.
        control.setImage(
            NSImage(systemSymbolName: "printer", accessibilityDescription: "Print"),
            forSegment: 0
        )
        control.setWidth(56, forSegment: 0)

        // Segment 1: export rendered document as PDF.
        control.setImage(
            NSImage(systemSymbolName: "square.and.arrow.up.on.square", accessibilityDescription: "Export as PDF"),
            forSegment: 1
        )
        control.setWidth(56, forSegment: 1)

        control.toolTip = "Print and export controls"
        control.isEnabled = isEnabled
        return control
    }

    func updateNSView(_ nsView: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        nsView.isEnabled = isEnabled
    }

    /// Coordinator that maps segment presses to the relevant document action.
    final class Coordinator: NSObject {
        /// Latest view configuration for callback access.
        var parent: DocumentActionSegmentedControl

        init(parent: DocumentActionSegmentedControl) {
            self.parent = parent
        }

        /// Handles segment activation and dispatches the mapped action.
        @objc func didActivateSegment(_ sender: NSSegmentedControl) {
            switch sender.selectedSegment {
            case 0:
                parent.onPrint()

            case 1:
                parent.onExportPDF()

            default:
                break
            }

            // Keep the control momentary so no segment remains selected.
            sender.selectedSegment = -1
        }
    }
}

/// Native single-segment control for opening files.
///
/// Keeping the open affordance inside an `NSSegmentedControl` ensures it
/// matches the same shape, padding, and interaction feel as the adjacent
/// zoom and appearance segmented controls.
private struct OpenSegmentedControl: NSViewRepresentable {
    /// Callback invoked when the user activates the open segment.
    let onOpenRequested: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.segmentCount = 1
        control.trackingMode = .momentary
        control.segmentStyle = .separated
        control.controlSize = .regular
        control.target = context.coordinator
        control.action = #selector(Coordinator.didActivateSegment(_:))

        control.setImage(
            NSImage(systemSymbolName: "folder", accessibilityDescription: "Open Markdown File"),
            forSegment: 0
        )
        control.setWidth(56, forSegment: 0)
        control.toolTip = "Open a Markdown file"

        return control
    }

    func updateNSView(_ nsView: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
    }

    /// Coordinator that forwards segment activation to SwiftUI callbacks.
    final class Coordinator: NSObject {
        /// Latest representable configuration used by the callback.
        var parent: OpenSegmentedControl

        init(parent: OpenSegmentedControl) {
            self.parent = parent
        }

        /// Handles activation of the open segment.
        @objc func didActivateSegment(_ sender: NSSegmentedControl) {
            parent.onOpenRequested()

            // Keep momentary behaviour so the segment does not stay selected.
            sender.selectedSegment = -1
        }
    }
}

/// Native macOS segmented control used for Preview-like zoom actions.
///
/// A momentary segmented control matches standard macOS utility-app behaviour:
/// each press invokes an action and immediately returns to an unselected state.
private struct ZoomSegmentedControl: NSViewRepresentable {
    /// Controls whether the zoom actions are available.
    let isEnabled: Bool

    /// Callback for zoom out action.
    let onZoomOut: () -> Void

    /// Callback for reset-to-actual-size action.
    let onActualSize: () -> Void

    /// Callback for zoom in action.
    let onZoomIn: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.segmentCount = 3
        control.trackingMode = .momentary
        // Use a native separated segmented style to better match Preview-like
        // rounded grouped controls with clear segment separators.
        control.segmentStyle = .separated
        control.controlSize = .regular
        control.target = context.coordinator
        control.action = #selector(Coordinator.didActivateSegment(_:))

        // Segment 0: zoom out icon.
        control.setImage(
            NSImage(systemSymbolName: "minus.magnifyingglass", accessibilityDescription: "Zoom Out"),
            forSegment: 0
        )
        control.setWidth(56, forSegment: 0)

        // Segment 1: use an actual-size zoom icon to mirror Preview-style
        // controls. Keep a text fallback for older symbol sets.
        if let actualSizeImage = NSImage(
            systemSymbolName: "1.magnifyingglass",
            accessibilityDescription: "Actual Size"
        ) {
            control.setImage(actualSizeImage, forSegment: 1)
            control.setWidth(56, forSegment: 1)
        } else {
            control.setLabel("100%", forSegment: 1)
            control.setWidth(72, forSegment: 1)
        }

        // Segment 2: zoom in icon.
        control.setImage(
            NSImage(systemSymbolName: "plus.magnifyingglass", accessibilityDescription: "Zoom In"),
            forSegment: 2
        )
        control.setWidth(56, forSegment: 2)

        control.toolTip = "Zoom controls"
        control.isEnabled = isEnabled
        return control
    }

    func updateNSView(_ nsView: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        nsView.isEnabled = isEnabled
    }

    /// Coordinator that translates selected segment index into app actions.
    final class Coordinator: NSObject {
        /// Latest view configuration for callback access.
        var parent: ZoomSegmentedControl

        init(parent: ZoomSegmentedControl) {
            self.parent = parent
        }

        /// Handles segment activation and forwards to the relevant callback.
        @objc func didActivateSegment(_ sender: NSSegmentedControl) {
            switch sender.selectedSegment {
            case 0:
                parent.onZoomOut()

            case 1:
                parent.onActualSize()

            case 2:
                parent.onZoomIn()

            default:
                break
            }

            // Keep the control momentary so no segment stays visually selected.
            sender.selectedSegment = -1
        }
    }
}

/// Native macOS segmented control used for explicit light/dark mode selection.
///
/// A select-one segmented control keeps the active appearance mode visible to
/// the user, mirroring macOS toolbar toggles.
private struct AppearanceSegmentedControl: NSViewRepresentable {
    /// True when dark appearance is currently active.
    let isDarkAppearanceActive: Bool

    /// Callback that sets light appearance mode.
    let onSetLightAppearance: () -> Void

    /// Callback that sets dark appearance mode.
    let onSetDarkAppearance: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.segmentCount = 2
        control.trackingMode = .selectOne
        // Keep the same rounded grouped style as the zoom control.
        control.segmentStyle = .separated
        control.controlSize = .regular
        control.selectedSegmentBezelColor = subtleSelectedSegmentBezelColour
        control.target = context.coordinator
        control.action = #selector(Coordinator.didActivateSegment(_:))

        control.setImage(
            NSImage(systemSymbolName: "sun.max", accessibilityDescription: "Light Mode"),
            forSegment: 0
        )
        control.setWidth(56, forSegment: 0)

        control.setImage(
            NSImage(systemSymbolName: "moon.fill", accessibilityDescription: "Dark Mode"),
            forSegment: 1
        )
        control.setWidth(56, forSegment: 1)

        control.selectedSegment = isDarkAppearanceActive ? 1 : 0
        control.toolTip = "Appearance mode"
        return control
    }

    func updateNSView(_ nsView: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        nsView.selectedSegmentBezelColor = subtleSelectedSegmentBezelColour
        nsView.selectedSegment = isDarkAppearanceActive ? 1 : 0
    }

    /// Subtle selection tint for the active appearance segment.
    ///
    /// We intentionally avoid the default vivid accent colour so the selected
    /// state remains visible without drawing too much attention in QuickMarkdownViewer's
    /// lightweight, document-first interface.
    private var subtleSelectedSegmentBezelColour: NSColor {
        NSColor(name: nil) { appearance in
            let isDarkAppearance = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

            if isDarkAppearance {
                // In dark mode, use a soft light overlay.
                return NSColor(white: 1.0, alpha: 0.18)
            } else {
                // In light mode, use a gentle neutral shade.
                return NSColor(white: 0.0, alpha: 0.08)
            }
        }
    }

    /// Coordinator that translates selected segment index into app actions.
    final class Coordinator: NSObject {
        /// Latest view configuration for callback access.
        var parent: AppearanceSegmentedControl

        init(parent: AppearanceSegmentedControl) {
            self.parent = parent
        }

        /// Handles segment selection and applies the requested appearance mode.
        @objc func didActivateSegment(_ sender: NSSegmentedControl) {
            switch sender.selectedSegment {
            case 0:
                parent.onSetLightAppearance()

            case 1:
                parent.onSetDarkAppearance()

            default:
                break
            }
        }
    }
}

/// Invisible helper that reports the hosting window number to SwiftUI state.
///
/// We use the window number to route app-level Find commands to exactly one
/// document window, even when multiple QuickMarkdownViewer windows are open.
private struct WindowNumberReader: NSViewRepresentable {
    /// Binding updated whenever the underlying AppKit window changes.
    @Binding var windowNumber: Int?

    /// Binding updated with object identity of the underlying AppKit window.
    @Binding var windowObjectID: ObjectIdentifier?

    func makeNSView(context: Context) -> ReportingView {
        let view = ReportingView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: ReportingView, context: Context) {
        configure(nsView)
        nsView.reportWindowNumber()
    }

    /// Wires binding updates without capturing a mutable struct self.
    private func configure(_ view: ReportingView) {
        let numberBinding = $windowNumber
        let objectIDBinding = $windowObjectID
        view.onWindowChanged = { newWindow in
            let newWindowNumber = newWindow?.windowNumber
            let newObjectID = newWindow.map(ObjectIdentifier.init)

            if numberBinding.wrappedValue != newWindowNumber {
                numberBinding.wrappedValue = newWindowNumber
            }

            if objectIDBinding.wrappedValue != newObjectID {
                objectIDBinding.wrappedValue = newObjectID
            }
        }
    }

    /// Small `NSView` subclass that reports its attached window details.
    final class ReportingView: NSView {
        /// Callback fired when window assignment changes.
        var onWindowChanged: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reportWindowNumber()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)

            // Defer reporting to next run loop so `window` is up to date.
            DispatchQueue.main.async { [weak self] in
                self?.reportWindowNumber()
            }
        }

        /// Sends the current `windowNumber` (or nil) to SwiftUI binding.
        func reportWindowNumber() {
            onWindowChanged?(window)
        }
    }
}
