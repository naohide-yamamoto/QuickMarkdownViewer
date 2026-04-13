import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Direction used for in-document Find actions.
enum MarkdownFindDirection {
    /// Search from the current match towards document end.
    case forwards

    /// Search from the current match towards document start.
    case backwards
}

/// Outcome of an "Export as PDF" request for a rendered Markdown document.
enum MarkdownPDFExportOutcome {
    /// The PDF was generated and written to the selected destination.
    case success

    /// The user cancelled the save panel.
    case cancelled

    /// Export failed due to rendering or file-write error.
    case failed
}

/// Thin bridge allowing SwiftUI controls to run Find actions in `WKWebView`.
///
/// We keep this as a separate object so `DocumentWindowView` can issue search
/// requests without directly owning AppKit view instances.
final class MarkdownWebViewSearchBridge: ObservableObject {
    /// Bound web view used by find/zoom/print/export operations.
    ///
    /// This is intentionally held strongly for reliability in exported Release
    /// builds where command actions can run after brief focus/view updates.
    /// `WKWebView` does not retain this bridge, so this does not create a
    /// reference cycle.
    private var webView: WKWebView?

    /// Minimum allowed zoom level for readability and layout stability.
    private let minimumPageZoom: CGFloat = 0.50

    /// Maximum allowed zoom level to avoid impractical scaling extremes.
    private let maximumPageZoom: CGFloat = 3.00

    /// Step size used by keyboard zoom shortcuts.
    private let pageZoomStep: CGFloat = 0.10

    /// Last zoom value produced by a successful zoom-to-fit command.
    ///
    /// We cache this so repeated `Cmd+9` presses at unchanged window size can
    /// be treated as intentional no-ops, avoiding visible "flash" from
    /// temporary baseline normalisation.
    private var lastAppliedFitZoom: CGFloat?

    /// Window/view width (in points) used for the cached fit result above.
    ///
    /// If the window is resized, this width changes and Cmd+9 should run a new
    /// fit solve rather than reusing/ignoring the previous state.
    private var lastAppliedFitViewWidth: CGFloat?

    /// Zoom equality tolerance used when deciding whether fit is already true.
    private let fitZoomTolerance: CGFloat = 0.01

    /// Width equality tolerance (points) for "same window size" checks.
    private let fitWidthTolerance: CGFloat = 0.5

    /// Horizontal breathing room kept around content during fit calculations.
    ///
    /// This mirrors Preview-style fit where text is not pressed against the
    /// window edge, preserving comfortable reading margins.
    private let horizontalFitGutterPoints: CGFloat = 80

    /// Minimum width used for fit maths on very small windows.
    ///
    /// A floor prevents divide-by-near-zero and avoids extreme zoom values
    /// during fast live-resize interactions on tiny window widths.
    private let minimumFitWidthPoints: CGFloat = 120

    /// Default maximum content-column width from bundled reader stylesheet.
    ///
    /// Keep this in sync with `.content { width: min(100%, 840px); }` in
    /// `QuickMarkdownViewer/Web/styles.css`.
    private let defaultContentColumnMaximumWidthPoints: CGFloat = 840

    /// Whether fit mode is currently active for this web view.
    ///
    /// Fit mode becomes active after a successful `Cmd+9`/smart-fit action and
    /// is cleared by manual zoom actions. While active, window-resize events
    /// should keep content fitted automatically.
    private var isZoomToFitModeEnabled = false

    /// Baseline content width measured at 100% zoom (in native points).
    ///
    /// This baseline enables deterministic fit recomputation for window-resize
    /// updates without temporarily resetting zoom (which causes flashing).
    private var fitBaselineContentWidthPoints: CGFloat?

    /// Temporary off-screen web views retained while print/PDF tasks run.
    ///
    /// We render print/export output in isolated web views so the main document
    /// window keeps its existing visual state while output is generated.
    private var temporaryOutputWebViews: [ObjectIdentifier: WKWebView] = [:]

    /// Temporary navigation delegates retained for isolated web-view loading.
    ///
    /// `WKWebView.navigationDelegate` is weak, so we retain delegates until
    /// each temporary view has completed loading.
    private var temporaryOutputDelegates: [ObjectIdentifier: TemporaryOutputLoadDelegate] = [:]

    /// Hidden helper windows that host temporary output web views.
    ///
    /// Keeping temporary web views in a dedicated AppKit window avoids adding
    /// subviews directly under SwiftUI's `NSHostingController.view`.
    private var temporaryOutputWindows: [ObjectIdentifier: NSWindow] = [:]

    /// Binds the current `WKWebView` instance after creation/update.
    ///
    /// Binding is idempotent, so repeated updates are cheap.
    func bind(webView: WKWebView) {
        if self.webView !== webView {
            self.webView = webView

            // Ensure each new document web view starts at true 100% zoom.
            webView.pageZoom = 1.0
            invalidateZoomToFitCache()
        }
    }

    /// Clears all zoom-to-fit state and exits fit mode.
    ///
    /// We invalidate fit state whenever user zoom changes or content reloads so
    /// the next fit command recomputes against fresh document/window context.
    func invalidateZoomToFitCache() {
        lastAppliedFitZoom = nil
        lastAppliedFitViewWidth = nil
        fitBaselineContentWidthPoints = nil
        isZoomToFitModeEnabled = false
    }

    /// Finds the next/previous occurrence of `query` in rendered content.
    ///
    /// We use an app-owned highlighter controller (injected into the page once)
    /// rather than `window.find(...)`, so match colours are fully controllable
    /// and remain clearly visible in both light and dark appearance.
    func find(
        query: String,
        direction: MarkdownFindDirection,
        isCaseSensitive: Bool,
        completion: @escaping (Bool) -> Void
    ) {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty, let webView else {
            completion(false)
            return
        }

        // Build a safe JS string literal via shared JSON escaping helper.
        let escapedQuery = SecurityHelpers.jsonStringLiteral(trimmedQuery)
        let backwardsLiteral = direction == .backwards ? "true" : "false"
        let caseSensitiveLiteral = isCaseSensitive ? "true" : "false"

        let script = """
        (() => {
            const root = document.getElementById("content");
            if (!root) {
                return false;
            }

            \(findControllerBootstrapJavaScript())

            return window.__quickMarkdownViewerFindController.run(
                root,
                \(escapedQuery),
                \(backwardsLiteral),
                \(caseSensitiveLiteral)
            );
        })();
        """

        webView.evaluateJavaScript(script) { result, error in
            if let error {
                Logger.error("Find failed in WKWebView: \(error.localizedDescription)")
                completion(false)
                return
            }

            completion((result as? Bool) ?? false)
        }
    }

    /// Clears any in-document Find highlights currently shown in the web view.
    ///
    /// This is used when the query becomes empty so stale highlights do not
    /// remain on screen after users clear the search field.
    @discardableResult
    func clearFindHighlights() -> Bool {
        guard let webView else {
            return false
        }

        let script = """
        (() => {
            const root = document.getElementById("content");
            if (!root) {
                return false;
            }

            \(findControllerBootstrapJavaScript())
            return window.__quickMarkdownViewerFindController.clear(root);
        })();
        """

        webView.evaluateJavaScript(script) { _, error in
            if let error {
                Logger.error("Clearing find highlights failed: \(error.localizedDescription)")
            }
        }

        return true
    }

    /// Presents the native macOS print panel for rendered document content.
    ///
    /// Important: this prints the `WKWebView` render output, not Markdown
    /// source text. That keeps print behaviour aligned with Preview-like usage.
    ///
    /// Returns `false` only when no web view is currently bound.
    @discardableResult
    func printRenderedDocument(attachedTo window: NSWindow?) -> Bool {
        guard webView != nil else {
            return false
        }

        let pageConfiguration = preferredPrintPageConfiguration()
        let hostWindow = window ?? NSApp.keyWindow ?? NSApp.mainWindow

        prepareTemporaryOutputWebView(
            attachedTo: hostWindow,
            pageConfiguration: pageConfiguration
        ) { [weak self] temporaryWebView in
            DispatchQueue.main.async {
                guard let self, let temporaryWebView else {
                    NSSound.beep()
                    return
                }

                let printInfo = self.configuredPrintInfo(for: pageConfiguration)
                self.createRenderedOutputPDFData(
                    from: temporaryWebView,
                    pageConfiguration: pageConfiguration
                ) { pdfData in
                    defer {
                        self.releaseTemporaryOutputResources(for: temporaryWebView)
                    }

                    guard let pdfData,
                          let document = PDFDocument(data: pdfData),
                          let operation = document.printOperation(
                              for: printInfo,
                              scalingMode: .pageScaleToFit,
                              autoRotate: true
                          ) else {
                        NSSound.beep()
                        Logger.error("Print failed: unable to create PDF print operation.")
                        return
                    }

                    operation.jobTitle = ""
                    operation.showsPrintPanel = true
                    operation.showsProgressPanel = true

                    if let hostWindow {
                        operation.runModal(for: hostWindow, delegate: nil, didRun: nil, contextInfo: nil)
                    } else {
                        _ = operation.run()
                    }
                }
            }
        }

        return true
    }

    /// Exports rendered web content to a PDF file chosen by the user.
    ///
    /// This uses the native print engine in silent save-to-PDF mode so
    /// pagination and margins match normal print output.
    func exportRenderedPDF(
        attachedTo window: NSWindow?,
        suggestedFilename: String,
        completion: @escaping (MarkdownPDFExportOutcome) -> Void
    ) {
        guard webView != nil else {
            completion(.failed)
            return
        }

        let pageConfiguration = preferredPrintPageConfiguration()
        let hostWindow = window ?? NSApp.keyWindow ?? NSApp.mainWindow

        prepareTemporaryOutputWebView(
            attachedTo: hostWindow,
            pageConfiguration: pageConfiguration
        ) { [weak self] temporaryWebView in
            guard let self else {
                completion(.failed)
                return
            }

            guard let temporaryWebView else {
                completion(.failed)
                return
            }

            let savePanel = NSSavePanel()
            savePanel.canCreateDirectories = true
            savePanel.nameFieldStringValue = suggestedFilename
            savePanel.allowedContentTypes = [.pdf]
            savePanel.isExtensionHidden = false
            // Leave title/message unset so macOS uses its standard compact save UI
            // without app-injected instructional header text.
            savePanel.prompt = "Export"

            let finish: (MarkdownPDFExportOutcome) -> Void = { outcome in
                self.releaseTemporaryOutputResources(for: temporaryWebView)
                completion(outcome)
            }

            let handlePanelResponse: (NSApplication.ModalResponse) -> Void = { response in
                guard response == .OK else {
                    finish(.cancelled)
                    return
                }

                guard let destinationURL = savePanel.url else {
                    finish(.failed)
                    return
                }

                self.createRenderedOutputPDFData(
                    from: temporaryWebView,
                    pageConfiguration: pageConfiguration
                ) { pdfData in
                    guard let pdfData else {
                        Logger.error("PDF export data generation failed.")
                        finish(.failed)
                        return
                    }

                    do {
                        try pdfData.write(to: destinationURL, options: .atomic)
                        finish(.success)
                    } catch {
                        Logger.error("Writing exported PDF failed: \(error.localizedDescription)")
                        finish(.failed)
                    }
                }
            }

            // Prefer sheet presentation (modern macOS standard) when a host
            // window is available. Fall back to modal panel only if needed.
            if let hostWindow {
                savePanel.beginSheetModal(for: hostWindow, completionHandler: handlePanelResponse)
            } else {
                let response = savePanel.runModal()
                handlePanelResponse(response)
            }
        }
    }

    /// Returns the current text selection from rendered document content.
    ///
    /// This powers macOS-standard Edit > Find actions:
    /// - Use Selection for Find (`Cmd+E`)
    /// - Jump to Selection (`Cmd+J`)
    ///
    /// The result is trimmed and delivered on the callback as:
    /// - non-empty selected text
    /// - `nil` when no usable selection exists
    func selectedText(completion: @escaping (String?) -> Void) {
        guard let webView else {
            completion(nil)
            return
        }

        let script = """
        (() => {
            const selection = window.getSelection();
            if (!selection) {
                return "";
            }
            return selection.toString();
        })();
        """

        webView.evaluateJavaScript(script) { result, error in
            if let error {
                Logger.error("Reading text selection failed: \(error.localizedDescription)")
                completion(nil)
                return
            }

            let text = (result as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            completion(text.isEmpty ? nil : text)
        }
    }

    /// JavaScript bootstrap for QuickMarkdownViewer's in-page find/highlight controller.
    ///
    /// The controller is created lazily and cached on `window`, so repeated
    /// Find actions can move among matches without reparsing on every step when
    /// the query text has not changed.
    private func findControllerBootstrapJavaScript() -> String {
        """
        if (!window.__quickMarkdownViewerFindController) {
            window.__quickMarkdownViewerFindController = (() => {
                const hitClass = "quickmarkdownviewer-find-hit";
                const activeClass = "quickmarkdownviewer-find-hit-active";

                const state = {
                    query: "",
                    isCaseSensitive: false,
                    activeIndex: -1
                };

                function getHits(root) {
                    return Array.from(root.querySelectorAll(`mark.${hitClass}`));
                }

                function clear(root) {
                    const hits = getHits(root);
                    for (const hit of hits) {
                        const parent = hit.parentNode;
                        if (!parent) {
                            continue;
                        }

                        parent.replaceChild(document.createTextNode(hit.textContent || ""), hit);
                        parent.normalize();
                    }

                    state.query = "";
                    state.isCaseSensitive = false;
                    state.activeIndex = -1;
                    return true;
                }

                function isSearchableTextNode(node) {
                    if (!node || typeof node.nodeValue !== "string" || node.nodeValue.length === 0) {
                        return false;
                    }

                    const parent = node.parentElement;
                    if (!parent) {
                        return false;
                    }

                    if (parent.closest(`mark.${hitClass}`)) {
                        return false;
                    }

                    const tagName = parent.tagName;
                    return tagName !== "SCRIPT" &&
                        tagName !== "STYLE" &&
                        tagName !== "NOSCRIPT" &&
                        tagName !== "TEXTAREA";
                }

                function highlightAll(root, query, isCaseSensitive) {
                    const queryLength = query.length;
                    const normalisedNeedle = isCaseSensitive
                        ? query
                        : query.toLocaleLowerCase();

                    const hits = [];
                    const walker = document.createTreeWalker(
                        root,
                        NodeFilter.SHOW_TEXT,
                        {
                            acceptNode(node) {
                                return isSearchableTextNode(node)
                                    ? NodeFilter.FILTER_ACCEPT
                                    : NodeFilter.FILTER_REJECT;
                            }
                        }
                    );

                    const textNodes = [];
                    while (walker.nextNode()) {
                        textNodes.push(walker.currentNode);
                    }

                    for (const textNode of textNodes) {
                        const sourceText = textNode.nodeValue || "";
                        const sourceSearchText = isCaseSensitive
                            ? sourceText
                            : sourceText.toLocaleLowerCase();

                        let searchFrom = 0;
                        let matchIndex = sourceSearchText.indexOf(normalisedNeedle, searchFrom);
                        if (matchIndex < 0) {
                            continue;
                        }

                        const fragment = document.createDocumentFragment();

                        while (matchIndex >= 0) {
                            if (matchIndex > searchFrom) {
                                fragment.appendChild(
                                    document.createTextNode(sourceText.slice(searchFrom, matchIndex))
                                );
                            }

                            const hit = document.createElement("mark");
                            hit.className = hitClass;
                            hit.textContent = sourceText.slice(matchIndex, matchIndex + queryLength);
                            fragment.appendChild(hit);
                            hits.push(hit);

                            searchFrom = matchIndex + queryLength;
                            matchIndex = sourceSearchText.indexOf(normalisedNeedle, searchFrom);
                        }

                        if (searchFrom < sourceText.length) {
                            fragment.appendChild(document.createTextNode(sourceText.slice(searchFrom)));
                        }

                        const parent = textNode.parentNode;
                        if (parent) {
                            parent.replaceChild(fragment, textNode);
                        }
                    }

                    return hits;
                }

                function activateMatch(hits, desiredIndex) {
                    const hitCount = hits.length;
                    if (hitCount === 0) {
                        state.activeIndex = -1;
                        return false;
                    }

                    let activeIndex = desiredIndex % hitCount;
                    if (activeIndex < 0) {
                        activeIndex += hitCount;
                    }

                    for (let i = 0; i < hitCount; i += 1) {
                        hits[i].classList.toggle(activeClass, i === activeIndex);
                    }

                    state.activeIndex = activeIndex;
                    hits[activeIndex].scrollIntoView({
                        block: "center",
                        inline: "nearest",
                        behavior: "auto"
                    });

                    return true;
                }

                function run(root, query, backwards, caseSensitive) {
                    const trimmedQuery = typeof query === "string"
                        ? query.trim()
                        : "";
                    const normalisedCaseSensitive = Boolean(caseSensitive);

                    if (!trimmedQuery) {
                        clear(root);
                        return false;
                    }

                    const sameQuery = state.query === trimmedQuery &&
                        state.isCaseSensitive === normalisedCaseSensitive;
                    if (!sameQuery) {
                        clear(root);
                        const hits = highlightAll(
                            root,
                            trimmedQuery,
                            normalisedCaseSensitive
                        );

                        state.query = trimmedQuery;
                        state.isCaseSensitive = normalisedCaseSensitive;
                        if (hits.length === 0) {
                            state.activeIndex = -1;
                            return false;
                        }

                        const initialIndex = backwards ? hits.length - 1 : 0;
                        return activateMatch(hits, initialIndex);
                    }

                    const hits = getHits(root);
                    if (hits.length === 0) {
                        state.activeIndex = -1;
                        return false;
                    }

                    const directionDelta = backwards ? -1 : 1;
                    const nextIndex = state.activeIndex >= 0
                        ? state.activeIndex + directionDelta
                        : (backwards ? hits.length - 1 : 0);

                    return activateMatch(hits, nextIndex);
                }

                return {
                    run,
                    clear
                };
            })();
        }
        """
    }

    /// Print-page geometry used for both print and PDF export.
    ///
    /// We always use portrait orientation and choose A4 vs US Letter based on
    /// the user's metric preference to keep output predictable without manual
    /// zoom adjustments.
    private struct PrintPageConfiguration {
        let paperSize: NSSize
        let marginPoints: CGFloat
        let outputSafetyInsetPoints: CGFloat

        var contentWidthPoints: CGFloat {
            max(200, paperSize.width - (marginPoints * 2) - (outputSafetyInsetPoints * 2))
        }

        var printableHeightPoints: CGFloat {
            max(200, paperSize.height - (marginPoints * 2) - (outputSafetyInsetPoints * 2))
        }
    }

    /// Minimal snapshot payload captured from the visible web view.
    private struct TemporaryOutputSnapshot {
        let contentHTML: String
        let stylesCSS: String
        let baseURL: URL?
    }

    /// Delegate used to detect completion of temporary web-view loading.
    private final class TemporaryOutputLoadDelegate: NSObject, WKNavigationDelegate {
        private var didComplete = false
        private let onSuccess: () -> Void
        private let onFailure: (Error?) -> Void

        init(onSuccess: @escaping () -> Void, onFailure: @escaping (Error?) -> Void) {
            self.onSuccess = onSuccess
            self.onFailure = onFailure
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            completeOnce {
                onSuccess()
            }
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            completeOnce {
                onFailure(error)
            }
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            completeOnce {
                onFailure(error)
            }
        }

        private func completeOnce(_ block: () -> Void) {
            guard !didComplete else { return }
            didComplete = true
            block()
        }
    }

    /// Chooses portrait A4 (metric) or US Letter (non-metric) page geometry.
    private func preferredPrintPageConfiguration() -> PrintPageConfiguration {
        let usesMetricSystem: Bool
        if #available(macOS 13.0, *) {
            usesMetricSystem = Locale.current.measurementSystem == .metric
        } else {
            usesMetricSystem = Locale.current.usesMetricSystem
        }

        if usesMetricSystem {
            // A4 portrait in points (72 DPI): 210mm x 297mm.
            return PrintPageConfiguration(
                paperSize: NSSize(width: 595.28, height: 841.89),
                marginPoints: 40,
                outputSafetyInsetPoints: 8
            )
        }

        // US Letter portrait in points.
        return PrintPageConfiguration(
            paperSize: NSSize(width: 612, height: 792),
            marginPoints: 36,
            outputSafetyInsetPoints: 8
        )
    }

    /// Builds `NSPrintInfo` with deterministic portrait page settings.
    private func configuredPrintInfo(for pageConfiguration: PrintPageConfiguration) -> NSPrintInfo {
        let printInfo = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo.shared
        printInfo.orientation = .portrait
        printInfo.paperSize = pageConfiguration.paperSize
        // Keep print-operation margins at zero because exported/print source
        // pages already include explicit content insets.
        printInfo.topMargin = 0
        printInfo.bottomMargin = 0
        printInfo.leftMargin = 0
        printInfo.rightMargin = 0
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered = false
        printInfo.horizontalPagination = .automatic
        printInfo.verticalPagination = .automatic
        printInfo.dictionary()[NSPrintInfo.AttributeKey.scalingFactor] = 1.0
        return printInfo
    }

    /// Prepares an isolated web view configured for print/PDF output.
    ///
    /// The temporary view is attached to a live host view but placed off-screen.
    /// This avoids visual changes in the main window while ensuring WebKit's
    /// print view gets a valid frame initialisation.
    private func prepareTemporaryOutputWebView(
        attachedTo _: NSWindow?,
        pageConfiguration: PrintPageConfiguration,
        completion: @escaping (WKWebView?) -> Void
    ) {
        captureTemporaryOutputSnapshot { [weak self] snapshot in
            guard let self, let snapshot else {
                completion(nil)
                return
            }

            let configuration = WKWebViewConfiguration()
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
            configuration.defaultWebpagePreferences.allowsContentJavaScript = false
            if let sourceWebView = self.webView {
                // Reuse the same website data store so print/export rendering
                // follows the same local-resource access context.
                configuration.websiteDataStore = sourceWebView.configuration.websiteDataStore
            }

            let targetWidth = pageConfiguration.contentWidthPoints
            let sourceHeight = self.webView?.bounds.height ?? 0
            let targetHeight = max(1200, sourceHeight > 0 ? sourceHeight : 1400)
            let helperWindowFrame = CGRect(
                x: -50_000,
                y: -50_000,
                width: targetWidth,
                height: targetHeight
            )

            // Host temporary output in a dedicated hidden AppKit window.
            let helperWindow = NSWindow(
                contentRect: helperWindowFrame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            helperWindow.isReleasedWhenClosed = false
            helperWindow.ignoresMouseEvents = true
            helperWindow.hasShadow = false
            helperWindow.backgroundColor = .clear
            helperWindow.level = .normal
            helperWindow.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]

            let helperContainer = NSView(
                frame: CGRect(origin: .zero, size: helperWindowFrame.size)
            )
            helperContainer.wantsLayer = true
            helperContainer.layer?.backgroundColor = NSColor.clear.cgColor
            helperWindow.contentView = helperContainer

            let temporaryWebView = WKWebView(frame: helperContainer.bounds, configuration: configuration)
            temporaryWebView.autoresizingMask = [.width, .height]
            let identifier = ObjectIdentifier(temporaryWebView)

            temporaryOutputWebViews[identifier] = temporaryWebView
            temporaryOutputWindows[identifier] = helperWindow
            helperContainer.addSubview(temporaryWebView)
            helperContainer.layoutSubtreeIfNeeded()
            helperWindow.displayIfNeeded()

            let loadDelegate = TemporaryOutputLoadDelegate(
                onSuccess: { [weak self, weak temporaryWebView] in
                    guard let self, let temporaryWebView else {
                        completion(nil)
                        return
                    }

                    self.measureStableRenderedContentHeight(in: temporaryWebView) { measuredHeight in
                        if let measuredHeight {
                            var resizedFrame = temporaryWebView.frame
                            resizedFrame.size.height = max(resizedFrame.size.height, measuredHeight)
                            temporaryWebView.frame = resizedFrame
                            temporaryWebView.layoutSubtreeIfNeeded()
                        }

                        let id = ObjectIdentifier(temporaryWebView)
                        helperContainer.layoutSubtreeIfNeeded()
                        helperWindow.displayIfNeeded()
                        temporaryWebView.navigationDelegate = nil
                        self.temporaryOutputDelegates[id] = nil
                        // Give AppKit one runloop turn to settle the helper view
                        // hierarchy before output generation begins.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            completion(temporaryWebView)
                        }
                    }
                },
                onFailure: { [weak self, weak temporaryWebView] error in
                    if let error {
                        Logger.error("Preparing temporary output web view failed: \(error.localizedDescription)")
                    }

                    if let self, let temporaryWebView {
                        self.releaseTemporaryOutputResources(for: temporaryWebView)
                    }

                    completion(nil)
                }
            )

            temporaryOutputDelegates[identifier] = loadDelegate
            temporaryWebView.navigationDelegate = loadDelegate
            temporaryWebView.loadHTMLString(
                temporaryOutputHTML(from: snapshot),
                baseURL: snapshot.baseURL
            )
        }
    }

    /// Measures rendered document height in points for off-screen pagination.
    ///
    /// `WKWebView` can otherwise report only viewport-sized output when printed
    /// off-screen, which leads to blank trailing pages.
    private func measureRenderedContentHeight(
        in webView: WKWebView,
        completion: @escaping (CGFloat?) -> Void
    ) {
        let script = """
        (() => {
            const root = document.getElementById("content");
            if (!root) {
                return null;
            }

            const body = document.body;
            const html = document.documentElement;
            const cssHeight = Math.max(
                root.scrollHeight || 0,
                root.offsetHeight || 0,
                body ? body.scrollHeight : 0,
                body ? body.offsetHeight : 0,
                html ? html.scrollHeight : 0,
                html ? html.offsetHeight : 0
            );

            const viewportWidth = window.innerWidth || 0;
            return { cssHeight, viewportWidth };
        })();
        """

        webView.evaluateJavaScript(script) { result, error in
            if let error {
                Logger.error("Measuring rendered content height failed: \(error.localizedDescription)")
                completion(nil)
                return
            }

            guard let payload = result as? [String: Any],
                  let cssHeight = self.doubleValue(fromJavaScript: payload["cssHeight"]),
                  cssHeight > 0,
                  let viewportWidth = self.doubleValue(fromJavaScript: payload["viewportWidth"]),
                  viewportWidth > 0 else {
                completion(nil)
                return
            }

            let pointsPerCSSPixel = Double(webView.bounds.width) / viewportWidth
            let measuredHeight = max(1000, cssHeight * pointsPerCSSPixel)
            Logger.info("Temporary output measured height: \(Int(measuredHeight))pt.")
            completion(CGFloat(measuredHeight))
        }
    }

    /// Measures rendered height until layout stabilises across several passes.
    ///
    /// Web content can keep changing briefly after `didFinish` (for example,
    /// late image decode/layout). If pagination starts too early, trailing
    /// content can be truncated. This helper polls a small number of times and
    /// returns the maximum observed height once values settle.
    private func measureStableRenderedContentHeight(
        in webView: WKWebView,
        completion: @escaping (CGFloat?) -> Void
    ) {
        let maximumAttempts = 10
        let settleDelaySeconds: TimeInterval = 0.18
        let settleTolerancePoints: CGFloat = 1.0
        var attempt = 0
        var stableReadings = 0
        var lastMeasuredHeight: CGFloat?
        var maximumMeasuredHeight: CGFloat = 0

        func runMeasurementPass() {
            measureRenderedContentHeight(in: webView) { measuredHeight in
                guard let measuredHeight else {
                    if maximumMeasuredHeight > 0 {
                        completion(maximumMeasuredHeight)
                    } else {
                        completion(nil)
                    }
                    return
                }

                maximumMeasuredHeight = max(maximumMeasuredHeight, measuredHeight)

                if let lastMeasuredHeight,
                   abs(measuredHeight - lastMeasuredHeight) <= settleTolerancePoints {
                    stableReadings += 1
                } else {
                    stableReadings = 0
                }

                attempt += 1
                // Keep the latest reading for the next settle comparison.
                lastMeasuredHeight = measuredHeight

                let isSettled = stableReadings >= 2
                let exhaustedAttempts = attempt >= maximumAttempts
                if isSettled || exhaustedAttempts {
                    Logger.info(
                        """
                        Temporary output settled height: \
                        \(Int(maximumMeasuredHeight))pt after \(attempt) pass(es).
                        """
                    )
                    completion(maximumMeasuredHeight)
                    return
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + settleDelaySeconds) {
                    runMeasurementPass()
                }
            }
        }

        if Thread.isMainThread {
            runMeasurementPass()
        } else {
            DispatchQueue.main.async {
                runMeasurementPass()
            }
        }
    }

    /// Generates PDF data from the temporary render view for export.
    ///
    /// `WKWebView.createPDF` renders one rectangle per call. We therefore
    /// generate one PDF page per printable slice and merge them into a single
    /// multi-page PDF document via PDFKit.
    private func createRenderedOutputPDFData(
        from temporaryWebView: WKWebView,
        pageConfiguration: PrintPageConfiguration,
        completion: @escaping (Data?) -> Void
    ) {
        let printableHeight = pageConfiguration.printableHeightPoints
        let contentWidth = pageConfiguration.contentWidthPoints
        let totalContentHeight = max(printableHeight, temporaryWebView.bounds.height)
        let pageCount = max(1, Int(ceil(totalContentHeight / printableHeight)))
        var pageDocuments: [PDFDocument] = []
        Logger.info(
            """
            PDF export generation started: pageWidth=\(Int(contentWidth))pt, \
            printableHeight=\(Int(printableHeight))pt, \
            totalHeight=\(Int(totalContentHeight))pt, \
            pageCount=\(pageCount).
            """
        )

        func finishMerge() {
            guard let mergedOutput = composeFullPagePDFData(
                from: pageDocuments,
                pageConfiguration: pageConfiguration
            ),
            !mergedOutput.data.isEmpty else {
                Logger.error("PDF export merge failed: no output pages.")
                completion(nil)
                return
            }

            Logger.info(
                """
                PDF export generation completed: mergedPages=\(mergedOutput.pageCount), \
                bytes=\(mergedOutput.data.count).
                """
            )
            completion(mergedOutput.data)
        }

        func renderPage(at pageIndex: Int) {
            guard pageIndex < pageCount else {
                finishMerge()
                return
            }

            let yOffset = CGFloat(pageIndex) * printableHeight
            let remainingHeight = max(1, totalContentHeight - yOffset)
            let sliceHeight = min(printableHeight, remainingHeight)

            let configuration = WKPDFConfiguration()
            configuration.rect = CGRect(
                x: 0,
                y: yOffset,
                width: contentWidth,
                height: sliceHeight
            )

            temporaryWebView.createPDF(configuration: configuration) { result in
                switch result {
                case .success(let pageData):
                    guard let pageDocument = PDFDocument(data: pageData),
                          pageDocument.pageCount > 0 else {
                        Logger.error("PDF export failed: generated page PDF was invalid at page \(pageIndex + 1).")
                        completion(nil)
                        return
                    }

                    Logger.info("PDF export page \(pageIndex + 1) generated: bytes=\(pageData.count), pdfPages=\(pageDocument.pageCount).")
                    pageDocuments.append(pageDocument)
                    renderPage(at: pageIndex + 1)

                case .failure(let error):
                    Logger.error("PDF export page generation failed at page \(pageIndex + 1): \(error.localizedDescription)")
                    completion(nil)
                }
            }
        }

        if Thread.isMainThread {
            renderPage(at: 0)
        } else {
            DispatchQueue.main.async {
                renderPage(at: 0)
            }
        }
    }

    /// Re-composes sliced content PDFs into full-size paper pages with insets.
    ///
    /// `WKWebView.createPDF` emits pages sized to the capture rect. We capture
    /// content-only slices for stable pagination, then place each slice onto a
    /// full A4/Letter page so exported/printed output has proper paper bounds
    /// and consistent margins.
    private func composeFullPagePDFData(
        from pageDocuments: [PDFDocument],
        pageConfiguration: PrintPageConfiguration
    ) -> (data: Data, pageCount: Int)? {
        let outputData = NSMutableData()
        guard let consumer = CGDataConsumer(data: outputData as CFMutableData) else {
            Logger.error("PDF export compose failed: unable to create data consumer.")
            return nil
        }

        var mediaBox = CGRect(origin: .zero, size: pageConfiguration.paperSize)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            Logger.error("PDF export compose failed: unable to create PDF context.")
            return nil
        }

        let pageRect = CGRect(origin: .zero, size: pageConfiguration.paperSize)
        let leftInset = pageConfiguration.marginPoints + pageConfiguration.outputSafetyInsetPoints
        let topInset = pageConfiguration.marginPoints + pageConfiguration.outputSafetyInsetPoints
        let maximumContentWidth = pageConfiguration.contentWidthPoints
        let maximumContentHeight = pageConfiguration.printableHeightPoints

        var writtenPageCount = 0

        for pageDocument in pageDocuments {
            for pageIndex in 0..<pageDocument.pageCount {
                guard let sourcePage = pageDocument.page(at: pageIndex),
                      let sourcePageRef = sourcePage.pageRef else {
                    continue
                }

                let sourceRect = sourcePageRef.getBoxRect(.mediaBox)
                guard sourceRect.width > 0, sourceRect.height > 0 else {
                    continue
                }

                let destinationWidth = min(maximumContentWidth, sourceRect.width)
                let destinationHeight = min(maximumContentHeight, sourceRect.height)
                let destinationRect = CGRect(
                    x: leftInset,
                    y: pageRect.height - topInset - destinationHeight,
                    width: destinationWidth,
                    height: destinationHeight
                )

                context.beginPDFPage(nil)
                context.setFillColor(NSColor.white.cgColor)
                context.fill(pageRect)

                context.saveGState()
                context.translateBy(x: destinationRect.minX, y: destinationRect.minY)
                context.scaleBy(
                    x: destinationRect.width / sourceRect.width,
                    y: destinationRect.height / sourceRect.height
                )
                context.drawPDFPage(sourcePageRef)
                context.restoreGState()

                context.endPDFPage()
                writtenPageCount += 1
            }
        }

        guard writtenPageCount > 0 else {
            Logger.error("PDF export compose failed: no pages were written.")
            return nil
        }

        context.closePDF()
        return (outputData as Data, writtenPageCount)
    }

    /// Captures rendered content plus inlined styles from the visible web view.
    private func captureTemporaryOutputSnapshot(completion: @escaping (TemporaryOutputSnapshot?) -> Void) {
        guard let webView else {
            completion(nil)
            return
        }

        let script = """
        (() => {
            const content = document.getElementById("content");
            if (!content) {
                return null;
            }

            const combinedStyles = Array
                .from(document.querySelectorAll("style"))
                .map(styleElement => styleElement.textContent || "")
                .join("\\n");

            const baseElement = document.querySelector("base");
            const baseURLString = baseElement
                ? baseElement.href
                : (document.baseURI || "");

            return {
                contentHTML: content.outerHTML,
                stylesCSS: combinedStyles,
                baseURLString
            };
        })();
        """

        webView.evaluateJavaScript(script) { result, error in
            if let error {
                Logger.error("Capturing temporary output snapshot failed: \(error.localizedDescription)")
                completion(nil)
                return
            }

            guard let payload = result as? [String: Any],
                  let contentHTML = payload["contentHTML"] as? String,
                  let stylesCSS = payload["stylesCSS"] as? String else {
                completion(nil)
                return
            }

            let baseURL = (payload["baseURLString"] as? String).flatMap { URL(string: $0) }
            Logger.info("Captured temporary output snapshot: contentLength=\(contentHTML.count), stylesLength=\(stylesCSS.count).")

            completion(
                TemporaryOutputSnapshot(
                    contentHTML: contentHTML,
                    stylesCSS: stylesCSS,
                    baseURL: baseURL
                )
            )
        }
    }

    /// Builds HTML for isolated print/PDF rendering.
    ///
    /// This explicitly enables `.qmv-print-output` mode so exported output is
    /// always light, content-only, and unaffected by current app appearance.
    private func temporaryOutputHTML(from snapshot: TemporaryOutputSnapshot) -> String {
        let baseURLString = snapshot.baseURL?.absoluteString ?? ""
        let escapedBaseURL = SecurityHelpers.htmlAttributeLiteral(baseURLString)

        return """
        <!doctype html>
        <html lang="en">
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <base href="\(escapedBaseURL)">
            <style>\(snapshot.stylesCSS)</style>
          </head>
          <body class="qmv-print-output">
            \(snapshot.contentHTML)
          </body>
        </html>
        """
    }

    /// Releases retained objects for one temporary output web view.
    private func releaseTemporaryOutputResources(for temporaryWebView: WKWebView) {
        let identifier = ObjectIdentifier(temporaryWebView)
        temporaryWebView.navigationDelegate = nil
        temporaryWebView.removeFromSuperview()
        if let helperWindow = temporaryOutputWindows[identifier] {
            helperWindow.orderOut(nil)
            helperWindow.contentView = nil
            helperWindow.close()
        }
        temporaryOutputDelegates[identifier] = nil
        temporaryOutputWebViews[identifier] = nil
        temporaryOutputWindows[identifier] = nil
    }

    /// Increases page zoom by one standard step.
    ///
    /// Returns `true` when a bound web view exists, regardless of whether the
    /// zoom value changed (for example, already at max zoom).
    @discardableResult
    func zoomIn() -> Bool {
        adjustZoom(delta: pageZoomStep)
    }

    /// Decreases page zoom by one standard step.
    ///
    /// Returns `true` when a bound web view exists, regardless of whether the
    /// zoom value changed (for example, already at min zoom).
    @discardableResult
    func zoomOut() -> Bool {
        adjustZoom(delta: -pageZoomStep)
    }

    /// Resets page zoom back to 100%.
    ///
    /// Returns `true` when a bound web view exists.
    @discardableResult
    func resetZoomToActualSize() -> Bool {
        guard let webView else {
            return false
        }

        webView.pageZoom = clampedPageZoom(1.0)
        invalidateZoomToFitCache()
        return true
    }

    /// Applies an absolute zoom value using the shared clamping rules.
    ///
    /// This is used by pinch-gesture handling so gesture zoom and keyboard
    /// zoom always follow the same model and the same min/max range.
    @discardableResult
    func setPageZoom(_ proposedZoom: CGFloat) -> Bool {
        guard let webView else {
            return false
        }

        webView.pageZoom = clampedPageZoom(proposedZoom)
        invalidateZoomToFitCache()
        return true
    }

    /// Returns the current page-zoom value from the bound web view.
    ///
    /// Gesture handling uses this value as the baseline when a pinch begins.
    func currentPageZoom() -> CGFloat? {
        webView?.pageZoom
    }

    /// Zooms the rendered document so the main content column fits the window.
    ///
    /// This uses a deterministic one-shot solver:
    /// 1. measure content width at a stable 100% baseline
    /// 2. compute the required absolute zoom from native view width
    /// 3. apply the clamped target zoom
    ///
    /// Because the fit target is solved from baseline metrics, one `Cmd+9`
    /// should land on the same fit zoom directly instead of iterating there.
    func zoomToFitWidth(completion: @escaping (Bool) -> Void) {
        guard let webView else {
            completion(false)
            return
        }

        // If current zoom already matches the last solved fit value at this
        // same window width, treat repeated Cmd+9 as a no-op.
        if isCurrentlyAtCachedFit(for: webView) {
            completion(true)
            return
        }

        // If fit mode is already active and we still have a baseline width,
        // we can re-fit immediately without JS/baseline reset (no flashing).
        if isZoomToFitModeEnabled, applyFitUsingBaseline(on: webView) {
            completion(true)
            return
        }

        let script = """
        (() => {
            const container = document.getElementById("content");
            if (!container) {
                return null;
            }

            const viewportWidth = window.innerWidth;
            const renderedContentWidth = container.getBoundingClientRect().width;
            const fallbackContentWidth = Math.max(container.offsetWidth, container.scrollWidth);

            if (!Number.isFinite(viewportWidth)) {
                return null;
            }

            return {
                viewportWidth,
                renderedContentWidth,
                fallbackContentWidth
            };
        })();
        """

        let originalZoom = webView.pageZoom

        // Solve fit from a stable baseline so the result does not depend on
        // the current zoom level from which the user triggers Cmd+9.
        if abs(originalZoom - 1.0) > 0.0001 {
            webView.pageZoom = 1.0
        }

        webView.evaluateJavaScript(script) { [weak webView] result, error in
            guard let webView else {
                completion(false)
                return
            }

            if let error {
                Logger.error("Zoom-to-fit metric read failed: \(error.localizedDescription)")
                // Restore prior zoom on failure so Cmd+9 is non-destructive.
                webView.pageZoom = originalZoom
                completion(false)
                return
            }

            guard let metrics = result as? [String: Any],
                  let viewportWidth = self.doubleValue(fromJavaScript: metrics["viewportWidth"]),
                  viewportWidth > 0 else {
                webView.pageZoom = originalZoom
                completion(false)
                return
            }

            let renderedContentWidth = self.doubleValue(fromJavaScript: metrics["renderedContentWidth"]) ?? 0
            let fallbackContentWidth = self.doubleValue(fromJavaScript: metrics["fallbackContentWidth"]) ?? 0
            let contentWidth = renderedContentWidth > 0 ? renderedContentWidth : fallbackContentWidth

            guard contentWidth > 0 else {
                webView.pageZoom = originalZoom
                completion(false)
                return
            }

            let viewWidthPoints = Double(webView.bounds.width)
            guard viewWidthPoints > 0 else {
                webView.pageZoom = originalZoom
                completion(false)
                return
            }

            // Convert CSS-pixel width into native-point width at baseline.
            let pointsPerCSSPixel = viewWidthPoints / viewportWidth
            let baselineContentWidthPoints = contentWidth * pointsPerCSSPixel
            guard baselineContentWidthPoints > 0 else {
                webView.pageZoom = originalZoom
                completion(false)
                return
            }

            // Cache baseline width and enter fit mode so subsequent window
            // resizes can re-fit deterministically without visible flashing.
            self.fitBaselineContentWidthPoints = CGFloat(baselineContentWidthPoints)
            self.isZoomToFitModeEnabled = true

            guard self.applyFitUsingBaseline(on: webView) else {
                webView.pageZoom = originalZoom
                completion(false)
                return
            }

            // Cache the applied fit state so immediate repeated Cmd+9 presses
            // can be ignored without re-running baseline normalisation.
            completion(true)
        }
    }

    /// Fast initial-fit path using bundled stylesheet geometry (no JS measure).
    ///
    /// This removes sporadic first-open outliers caused by synchronous layout
    /// metric reads while preserving the same fit target as the default style.
    @discardableResult
    func zoomToFitWidthUsingDefaultColumnLayoutIfPossible() -> Bool {
        guard let webView else {
            return false
        }

        let viewWidthPoints = webView.bounds.width
        guard viewWidthPoints > 0 else {
            return false
        }

        let baselineContentWidthPoints = min(viewWidthPoints, defaultContentColumnMaximumWidthPoints)
        guard baselineContentWidthPoints > 0 else {
            return false
        }

        fitBaselineContentWidthPoints = baselineContentWidthPoints
        isZoomToFitModeEnabled = true
        return applyFitUsingBaseline(on: webView)
    }

    /// Re-applies fit after a window-size change when fit mode is active.
    ///
    /// This is called by the coordinator on `NSWindow.didResizeNotification`.
    /// Returns `true` when the call was handled (including no-op cases).
    @discardableResult
    func refitAfterWindowResizeIfNeeded() -> Bool {
        guard isZoomToFitModeEnabled, let webView else {
            return false
        }

        // If we are already fitted at this width, nothing to do.
        if isCurrentlyAtCachedFit(for: webView) {
            return true
        }

        return applyFitUsingBaseline(on: webView)
    }

    /// Applies a zoom delta while clamping to safe bounds.
    ///
    /// This keeps zoom behaviour predictable and prevents excessive scaling
    /// that can break readability or document layout.
    @discardableResult
    private func adjustZoom(delta: CGFloat) -> Bool {
        guard let webView else {
            return false
        }

        webView.pageZoom = clampedPageZoom(webView.pageZoom + delta)
        invalidateZoomToFitCache()
        return true
    }

    /// Applies fit zoom using cached baseline width and current view width.
    ///
    /// This path is deterministic and flicker-free because it does not need to
    /// temporarily reset to 100% or run JavaScript measurements each time.
    @discardableResult
    private func applyFitUsingBaseline(on webView: WKWebView) -> Bool {
        guard let baselineContentWidthPoints = fitBaselineContentWidthPoints,
              baselineContentWidthPoints > 0 else {
            return false
        }

        let availableWidthPoints = availableFitWidthPoints(for: webView.bounds.width)
        guard availableWidthPoints > 0 else {
            return false
        }

        let targetZoom = availableWidthPoints / baselineContentWidthPoints
        webView.pageZoom = clampedPageZoom(targetZoom)
        lastAppliedFitZoom = webView.pageZoom
        lastAppliedFitViewWidth = webView.bounds.width
        return true
    }

    /// Converts the current view width into the width budget for fit maths.
    ///
    /// Fit keeps side breathing room for readability, but still enforces a
    /// minimum width floor so very small windows remain numerically stable.
    private func availableFitWidthPoints(for viewWidth: CGFloat) -> CGFloat {
        max(minimumFitWidthPoints, viewWidth - horizontalFitGutterPoints)
    }

    /// Returns true when zoom and width still match the last solved fit state.
    private func isCurrentlyAtCachedFit(for webView: WKWebView) -> Bool {
        guard let lastAppliedFitZoom,
              let lastAppliedFitViewWidth else {
            return false
        }

        return abs(webView.pageZoom - lastAppliedFitZoom) <= fitZoomTolerance &&
            abs(webView.bounds.width - lastAppliedFitViewWidth) <= fitWidthTolerance
    }

    /// Normalises an arbitrary zoom value into QuickMarkdownViewer's supported range.
    private func clampedPageZoom(_ proposedZoom: CGFloat) -> CGFloat {
        max(minimumPageZoom, min(maximumPageZoom, proposedZoom))
    }

    /// Converts JavaScript numeric values into Swift `Double`.
    private func doubleValue(fromJavaScript value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }

        if let double = value as? Double {
            return double
        }

        return nil
    }

}

/// SwiftUI wrapper around `WKWebView` used for Markdown rendering.
///
/// Responsibilities:
/// - configure a constrained web view
/// - load rendered HTML with base URL for relative assets
/// - intercept clicked links and delegate routing decisions
struct MarkdownWebView: NSViewRepresentable {
    /// Fully rendered HTML document to display.
    let html: String

    /// Base directory URL used for relative links and images.
    let baseURL: URL

    /// Current source Markdown file URL.
    let documentURL: URL

    /// Callback used when local Markdown links should open in app.
    let onOpenMarkdown: (URL) -> Void

    /// Bridge object used by document-level Find controls.
    let searchBridge: MarkdownWebViewSearchBridge

    /// User setting controlling how much outer background framing is visible.
    let windowBackgroundVisibility: Double

    /// User-selected light-mode background colour (`#RRGGBB`).
    let windowBackgroundColorLightHex: String

    /// User-selected dark-mode background colour (`#RRGGBB`).
    let windowBackgroundColorDarkHex: String

    /// Creates coordinator used for navigation delegate callbacks.
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// Builds and configures the underlying `WKWebView`.
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()

        // Prevent JS from spawning extra windows.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        // JavaScript is required for bundled markdown-it rendering logic.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false

        // Disable WebKit's built-in magnification path because it has
        // different behaviour from `pageZoom` around 100%. We attach our own
        // pinch recogniser below so gestures and keyboard zoom stay consistent.
        webView.allowsMagnification = false

        // Bind immediately so command actions can work even before the first
        // `updateNSView` pass completes.
        searchBridge.bind(webView: webView)

        return webView
    }

    /// Updates coordinator state and reloads HTML when content changes.
    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.currentDocumentURL = documentURL
        context.coordinator.baseDirectoryURL = baseURL
        context.coordinator.onOpenMarkdown = onOpenMarkdown
        context.coordinator.searchBridge = searchBridge
        context.coordinator.windowBackgroundVisibility = windowBackgroundVisibility
        context.coordinator.windowBackgroundColorLightHex = windowBackgroundColorLightHex
        context.coordinator.windowBackgroundColorDarkHex = windowBackgroundColorDarkHex
        context.coordinator.installMagnifyEventMonitorIfNeeded(on: webView)
        context.coordinator.installWebViewSizeObserverIfNeeded(on: webView)
        searchBridge.bind(webView: webView)

        // Avoid redundant reloads when neither path nor content changed.
        let fingerprint = "\(baseURL.path)|\(html.hashValue)"
        if context.coordinator.lastLoadedFingerprint != fingerprint {
            context.coordinator.lastLoadedFingerprint = fingerprint
            context.coordinator.shouldApplyInitialZoomToFitOnNextDidFinish = true
            context.coordinator.prepareForLoadTransition(on: webView)
            context.coordinator.lastHTMLLoadStartedAt = DispatchTime.now()
            Logger.info(
                "[PERF] webview-load-start file=\(documentURL.lastPathComponent) htmlBytes=\(html.utf8.count)"
            )
            searchBridge.invalidateZoomToFitCache()
            webView.loadHTMLString(html, baseURL: baseURL)
        }

        // Apply window-background settings without forcing a reload so slider
        // and colour-picker updates feel immediate.
        context.coordinator.applyWindowBackgroundPreferencesIfNeeded(on: webView)
    }

    /// Navigation delegate object used by the web view.
    final class Coordinator: NSObject, WKNavigationDelegate {
        /// Currently displayed Markdown source file.
        var currentDocumentURL: URL?

        /// Base folder for resolving relative local links.
        var baseDirectoryURL: URL = URL(fileURLWithPath: "/")

        /// Callback for opening local Markdown links in QuickMarkdownViewer.
        var onOpenMarkdown: (URL) -> Void = { _ in }

        /// Bridge used to apply zoom updates with shared clamping rules.
        var searchBridge: MarkdownWebViewSearchBridge?

        /// Requested window-background framing level (`0...1`).
        var windowBackgroundVisibility: Double = AppPreferenceDefault.windowBackgroundVisibility

        /// Raw persisted light-mode background colour (`#RRGGBB`).
        var windowBackgroundColorLightHex: String = AppPreferenceDefault.windowBackgroundColorLightHex

        /// Raw persisted dark-mode background colour (`#RRGGBB`).
        var windowBackgroundColorDarkHex: String = AppPreferenceDefault.windowBackgroundColorDarkHex

        /// Fingerprint of last loaded HTML to avoid unnecessary reloads.
        var lastLoadedFingerprint = ""

        /// Start timestamp for the most recent `loadHTMLString` call.
        var lastHTMLLoadStartedAt: DispatchTime?

        /// One-shot flag to auto-apply fit right after fresh document load.
        ///
        /// This keeps initial document presentation consistent with the default
        /// fit-mode behaviour expected by this viewer.
        var shouldApplyInitialZoomToFitOnNextDidFinish = false

        /// One-shot flag to fade in content after each newly started HTML load.
        private var shouldRevealAfterNextLoad = false

        /// Last applied window-background framing level.
        private var lastAppliedWindowBackgroundVisibility: Double?

        /// Last applied light-mode custom-colour hex value.
        private var lastAppliedWindowBackgroundColorLightHex: String?

        /// Last applied dark-mode custom-colour hex value.
        private var lastAppliedWindowBackgroundColorDarkHex: String?

        /// Weak reference to the currently monitored web view instance.
        private weak var monitoredWebView: WKWebView?

        /// Local event-monitor token for trackpad zoom-related gestures.
        private var zoomEventMonitor: Any?

        /// Web view currently observed for frame/bounds size notifications.
        private weak var observedWebViewForSizeChanges: WKWebView?

        /// Notification token for frame size callbacks.
        private var webViewFrameObserver: NSObjectProtocol?

        /// Notification token for bounds size callbacks.
        private var webViewBoundsObserver: NSObjectProtocol?

        /// Debounced work item used to re-fit after window-size changes.
        ///
        /// Live resizing can emit a burst of size-change notifications. We
        /// debounce them so fit runs against settled `WKWebView` dimensions.
        private var pendingResizeRefitWorkItem: DispatchWorkItem?

        /// Small debounce delay for resize-driven fit recomputation.
        ///
        /// This keeps dynamic resize responsive while avoiding redundant fit
        /// work during rapid drag events.
        private let resizeRefitDebounceSeconds: TimeInterval = 0.01

        /// Link router that decides whether to allow or cancel navigation.
        private let linkRoutingService = LinkRoutingService()

        deinit {
            if let zoomEventMonitor {
                NSEvent.removeMonitor(zoomEventMonitor)
            }

            removeWebViewSizeObservers()

            pendingResizeRefitWorkItem?.cancel()
        }

        /// Installs one local zoom-event monitor and tracks the web view.
        ///
        /// A local monitor is more reliable here than recogniser callbacks in
        /// `WKWebView`, because web content internals can consume gesture paths.
        func installMagnifyEventMonitorIfNeeded(on webView: WKWebView) {
            monitoredWebView = webView

            guard zoomEventMonitor == nil else {
                return
            }

            zoomEventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.magnify, .smartMagnify]
            ) {
                [weak self] event in
                guard let self else { return event }

                let didHandleEvent: Bool
                switch event.type {
                case .magnify:
                    didHandleEvent = self.handleMagnifyEvent(event)

                case .smartMagnify:
                    didHandleEvent = self.handleSmartMagnifyEvent(event)

                default:
                    didHandleEvent = false
                }

                return didHandleEvent ? nil : event
            }
        }

        /// Installs observers that track web-view frame/bounds size changes.
        ///
        /// Using the web-view notifications (rather than window notifications)
        /// ensures fit maths runs against the actual settled content viewport.
        func installWebViewSizeObserverIfNeeded(on webView: WKWebView) {
            monitoredWebView = webView

            guard observedWebViewForSizeChanges !== webView else {
                return
            }

            removeWebViewSizeObservers()
            observedWebViewForSizeChanges = webView

            webView.postsFrameChangedNotifications = true
            webView.postsBoundsChangedNotifications = true

            webViewFrameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: webView,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleDebouncedResizeRefit()
            }

            webViewBoundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: webView,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleDebouncedResizeRefit()
            }
        }

        /// Schedules one debounced resize-driven fit update.
        ///
        /// Debouncing keeps live-resize smooth while still converging quickly
        /// to the same fit level users get from `Cmd+9`.
        private func scheduleDebouncedResizeRefit() {
            pendingResizeRefitWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self,
                      let monitoredWebView = self.monitoredWebView,
                      monitoredWebView.window != nil else {
                    return
                }

                _ = self.searchBridge?.refitAfterWindowResizeIfNeeded()
            }

            pendingResizeRefitWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + resizeRefitDebounceSeconds,
                execute: workItem
            )
        }

        /// Removes any existing web-view size observers.
        private func removeWebViewSizeObservers() {
            if let webViewFrameObserver {
                NotificationCenter.default.removeObserver(webViewFrameObserver)
                self.webViewFrameObserver = nil
            }

            if let webViewBoundsObserver {
                NotificationCenter.default.removeObserver(webViewBoundsObserver)
                self.webViewBoundsObserver = nil
            }

            observedWebViewForSizeChanges = nil
        }

        /// Handles one macOS magnify event and applies it to `pageZoom`.
        ///
        /// `NSEvent.magnification` is a zoom delta that should be added to the
        /// current scale, so this path aligns naturally with our zoom model.
        private func handleMagnifyEvent(_ event: NSEvent) -> Bool {
            guard let webView = monitoredWebView,
                  let bridge = searchBridge else {
                return false
            }

            // Ignore events from other windows.
            guard event.window === webView.window else {
                return false
            }

            // Only handle gestures occurring over this web view's bounds.
            let pointInWebView = webView.convert(event.locationInWindow, from: nil)
            guard webView.bounds.contains(pointInWebView) else {
                return false
            }

            let currentZoom = bridge.currentPageZoom() ?? 1.0
            _ = bridge.setPageZoom(currentZoom + event.magnification)
            return true
        }

        /// Handles smart-magnify gestures (two-finger double-tap on trackpad).
        ///
        /// This is the standard macOS smart-zoom gesture, mapped to QuickMarkdownViewer's
        /// one-way zoom-to-fit action.
        private func handleSmartMagnifyEvent(_ event: NSEvent) -> Bool {
            guard let webView = monitoredWebView,
                  let bridge = searchBridge else {
                return false
            }

            // Ignore events from other windows.
            guard event.window === webView.window else {
                return false
            }

            // Only handle gestures occurring over this web view's bounds.
            let pointInWebView = webView.convert(event.locationInWindow, from: nil)
            guard webView.bounds.contains(pointInWebView) else {
                return false
            }

            bridge.zoomToFitWidth { success in
                if !success {
                    NSSound.beep()
                }
            }

            return true
        }

        /// Intercepts clicked links and applies QuickMarkdownViewer routing policy.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            let decision = linkRoutingService.route(
                url: url,
                currentDocumentURL: currentDocumentURL,
                baseDirectoryURL: baseDirectoryURL,
                onOpenMarkdown: onOpenMarkdown
            )

            switch decision {
            case .allow:
                decisionHandler(.allow)
            case .cancel:
                decisionHandler(.cancel)
            }
        }

        /// Applies default fit mode once after each document load completes.
        ///
        /// This makes newly opened documents immediately fit the window without
        /// requiring the user to press `Cmd+9` first.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let loadStart = lastHTMLLoadStartedAt {
                let loadMilliseconds = elapsedMilliseconds(since: loadStart)
                Logger.info(
                    "[PERF] webview-didFinish file=\(currentDocumentURL?.lastPathComponent ?? "unknown") ms=\(formatMilliseconds(loadMilliseconds))"
                )
                lastHTMLLoadStartedAt = nil
            }

            // Reveal as soon as WebKit signals load completion so first-open
            // feels responsive even if fit-mode adjustment takes longer.
            revealAfterLoadIfNeeded(on: webView)

            // Reapply preferences after each load because the DOM was rebuilt.
            applyWindowBackgroundPreferencesIfNeeded(on: webView, force: true)

            guard shouldApplyInitialZoomToFitOnNextDidFinish else {
                return
            }

            shouldApplyInitialZoomToFitOnNextDidFinish = false
            DispatchQueue.main.async {
                let fitStart = DispatchTime.now()
                if self.searchBridge?.zoomToFitWidthUsingDefaultColumnLayoutIfPossible() == true {
                    let fitMilliseconds = self.elapsedMilliseconds(since: fitStart)
                    Logger.info(
                        "[PERF] initial-fit file=\(self.currentDocumentURL?.lastPathComponent ?? "unknown") success=true ms=\(self.formatMilliseconds(fitMilliseconds))"
                    )
                    return
                }

                self.searchBridge?.zoomToFitWidth { success in
                    let fitMilliseconds = self.elapsedMilliseconds(since: fitStart)
                    Logger.info(
                        "[PERF] initial-fit file=\(self.currentDocumentURL?.lastPathComponent ?? "unknown") success=\(success) ms=\(self.formatMilliseconds(fitMilliseconds))"
                    )
                    if !success {
                        Logger.error("Initial zoom-to-fit after document load failed.")
                    }
                }
            }
        }

        /// Restores visible content if a navigation fails before completion.
        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            shouldRevealAfterNextLoad = false
            webView.alphaValue = 1.0
        }

        /// Restores visible content if provisional navigation fails.
        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            shouldRevealAfterNextLoad = false
            webView.alphaValue = 1.0
        }

        /// Prepares the web view for a smoother first paint during fresh loads.
        func prepareForLoadTransition(on webView: WKWebView) {
            shouldRevealAfterNextLoad = true
            webView.alphaValue = 0.0
        }

        /// Performs a short fade-in once loaded content is ready for display.
        private func revealAfterLoadIfNeeded(on webView: WKWebView) {
            guard shouldRevealAfterNextLoad else {
                return
            }

            shouldRevealAfterNextLoad = false
            webView.alphaValue = 1.0
        }

        /// Applies user-selected window-background preferences to the web page.
        ///
        /// This avoids full HTML reloads for Settings changes and keeps updates
        /// immediate while users drag the visibility slider.
        func applyWindowBackgroundPreferencesIfNeeded(on webView: WKWebView, force: Bool = false) {
            let clampedVisibility = max(0.0, min(1.0, windowBackgroundVisibility))
            let normalizedLightHex = normalizedHexColor(
                windowBackgroundColorLightHex,
                fallback: AppPreferenceDefault.windowBackgroundColorLightHex
            )
            let normalizedDarkHex = normalizedHexColor(
                windowBackgroundColorDarkHex,
                fallback: AppPreferenceDefault.windowBackgroundColorDarkHex
            )

            let shouldApply = force ||
                lastAppliedWindowBackgroundVisibility != clampedVisibility ||
                lastAppliedWindowBackgroundColorLightHex != normalizedLightHex ||
                lastAppliedWindowBackgroundColorDarkHex != normalizedDarkHex

            guard shouldApply else {
                return
            }

            lastAppliedWindowBackgroundVisibility = clampedVisibility
            lastAppliedWindowBackgroundColorLightHex = normalizedLightHex
            lastAppliedWindowBackgroundColorDarkHex = normalizedDarkHex

            let visibilityLiteral = String(format: "%.4f", clampedVisibility)
            let lightHexLiteral = SecurityHelpers.jsonStringLiteral(normalizedLightHex)
            let darkHexLiteral = SecurityHelpers.jsonStringLiteral(normalizedDarkHex)

            let script = """
            (() => {
                const root = document.documentElement;
                const body = document.body;
                if (!root || !body) { return; }

                const visibility = \(visibilityLiteral);
                root.style.setProperty(
                    '--qmv-background-scale',
                    String(Math.max(0, Math.min(1, visibility)))
                );
                root.style.setProperty('--qmv-background-custom-color-light', \(lightHexLiteral));
                root.style.setProperty('--qmv-background-custom-color-dark', \(darkHexLiteral));
            })();
            """

            webView.evaluateJavaScript(script) { _, error in
                if let error {
                    Logger.error("Failed to apply window background settings: \(error.localizedDescription)")
                }
            }
        }

        /// Returns a safe `#RRGGBB` value suitable for CSS injection.
        private func normalizedHexColor(_ candidate: String, fallback fallbackHex: String) -> String {
            if let sanitized = sanitizedHexColor(candidate) {
                return sanitized
            }

            if let fallback = sanitizedHexColor(fallbackHex) {
                return fallback
            }

            return AppPreferenceDefault.windowBackgroundColorLightHex
        }

        /// Returns `#RRGGBB` when `candidate` is valid, otherwise `nil`.
        private func sanitizedHexColor(_ candidate: String) -> String? {
            let trimmed = candidate
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            let rawHex = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed

            let isValidHex = rawHex.count == 6 &&
                rawHex.allSatisfy { char in
                    char.isHexDigit
                }

            if isValidHex {
                return "#\(rawHex)"
            }

            return nil
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

        /// Called when the dedicated WebContent process crashes or is killed.
        ///
        /// We only log here for now; keeping behaviour minimal avoids masking
        /// the root cause while still surfacing useful diagnostics in Xcode.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            shouldRevealAfterNextLoad = false
            webView.alphaValue = 1.0
            Logger.error("WKWebView WebContent process terminated unexpectedly.")
        }
    }
}
