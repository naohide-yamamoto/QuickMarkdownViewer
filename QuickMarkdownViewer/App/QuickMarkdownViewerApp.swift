import SwiftUI
import Darwin
import WebKit

/// User-default keys backing app-level settings.
enum AppPreferenceKey {
    /// Default width (points) for newly opened windows.
    static let defaultWindowWidth = "qmv.defaultWindowWidth"

    /// Default height (points) for newly opened windows.
    static let defaultWindowHeight = "qmv.defaultWindowHeight"

    /// Controls how much outer window background is visible.
    ///
    /// Range: `0.0 ... 1.0`
    /// - `0.0`: rendered Markdown fills the full window.
    /// - `1.0`: legacy full background framing.
    static let windowBackgroundVisibility = "qmv.windowBackgroundVisibility"

    /// Hex colour string (`#RRGGBB`) used for light-mode window background.
    static let windowBackgroundColorLightHex = "qmv.windowBackgroundColorLightHex"

    /// Hex colour string (`#RRGGBB`) used for dark-mode window background.
    static let windowBackgroundColorDarkHex = "qmv.windowBackgroundColorDarkHex"

    /// True when automatic release-metadata checks are enabled.
    static let automaticUpdateCheckEnabled = "qmv.automaticUpdateCheckEnabled"

    /// True when fenced-code syntax highlighting is enabled.
    static let syntaxHighlightingEnabled = "qmv.syntaxHighlightingEnabled"

    /// Selected syntax-highlighting theme family.
    static let syntaxHighlightingTheme = "qmv.syntaxHighlightingTheme"

    /// Selected document typeface for rendered Markdown typography.
    static let documentTypeface = "qmv.documentTypeface"

    /// Selected document density variant.
    static let documentDensity = "qmv.documentDensity"

    /// Selected toolbar button size.
    static let toolbarButtonSize = "qmv.toolbarButtonSize"

}

/// Default values for app-level settings.
enum AppPreferenceDefault {
    /// Default width for newly opened windows.
    static let defaultWindowWidth = 940

    /// Default height for newly opened windows.
    static let defaultWindowHeight = 760

    /// v1.0.6 default: about half the legacy v1.0.5 background framing.
    static let windowBackgroundVisibility = 0.5

    /// Default selected light-mode background colour.
    static let windowBackgroundColorLightHex = "#F6F5F2"

    /// Default selected dark-mode background colour.
    static let windowBackgroundColorDarkHex = "#16181B"

    /// Default update-check mode: manual only.
    static let automaticUpdateCheckEnabled = false

    /// Default syntax-highlighting mode: off.
    static let syntaxHighlightingEnabled = false

    /// Default syntax-highlighting theme: GitHub.
    static let syntaxHighlightingTheme = SyntaxHighlightTheme.github.rawValue

    /// Default document typeface.
    static let documentTypeface = DocumentTypeface.sansSerif.rawValue

    /// Default document density.
    static let documentDensity = DocumentDensity.standard.rawValue

    /// Default toolbar button size.
    static let toolbarButtonSize = ToolbarButtonSizePreference.small.rawValue
}

/// Available document typefaces for rendered Markdown typography.
enum DocumentTypeface: String, CaseIterable, Identifiable {
    case sansSerif = "sans-serif"
    case serif

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sansSerif:
            return "Sans-serif"
        case .serif:
            return "Serif"
        }
    }

    static func resolved(from rawValue: String) -> Self {
        let normalizedRawValue = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return DocumentTypeface(rawValue: normalizedRawValue) ?? .sansSerif
    }
}

/// Available density variants for rendered Markdown typography.
enum DocumentDensity: String, CaseIterable, Identifiable {
    case standard
    case compact

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard:
            return "Standard"
        case .compact:
            return "Compact"
        }
    }

    static func resolved(from rawValue: String) -> Self {
        let normalizedRawValue = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return DocumentDensity(rawValue: normalizedRawValue) ?? .standard
    }
}

/// Available toolbar button-size preferences.
enum ToolbarButtonSizePreference: String, CaseIterable, Identifiable {
    case small
    case standard

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .small:
            return "Small"
        case .standard:
            return "Standard"
        }
    }

    static func resolved(from rawValue: String) -> Self {
        let normalizedRawValue = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return ToolbarButtonSizePreference(rawValue: normalizedRawValue) ?? .small
    }
}

/// Available syntax-highlighting theme families.
enum SyntaxHighlightTheme: String, CaseIterable, Identifiable {
    case github
    case vscode
    case atomOne
    case stackOverflow

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .github:
            return "GitHub"
        case .vscode:
            return "VS Code"
        case .atomOne:
            return "Atom One"
        case .stackOverflow:
            return "Stack Overflow"
        }
    }

    static func resolved(from rawValue: String) -> Self {
        SyntaxHighlightTheme(rawValue: rawValue) ?? .github
    }
}

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
            QuickMarkdownViewerSettingsView(routing: routing)
        }
        .commands {
            // Install a small command set that mirrors standard macOS
            // expectations for a document viewer.
            AppCommands(routing: routing)
        }
    }
}

/// v1.0.6 settings panel with tab-specific controls and reset actions.
private struct QuickMarkdownViewerSettingsView: View {
    /// Sentinel picker ID used for the bottom "Select…" action row.
    private static let selectDefaultViewerOptionID = "__qmv.selectDefaultViewer__"

    /// Sentinel picker ID used for View Source app "Select…" action row.
    private static let selectViewSourceAppOptionID = "__qmv.selectViewSourceApp__"

    /// Tabs shown in the Settings window.
    private enum SettingsTab: Hashable {
        case general
        case appearance
    }

    /// Focusable fields within the default window-size row.
    private enum WindowSizeFieldFocus: Hashable {
        case width
        case height
    }

    /// Shared app router used for update checks and appearance resets.
    @ObservedObject var routing: AppRouting

    @AppStorage(
        AppPreferenceKey.defaultWindowWidth
    ) private var defaultWindowWidth = AppPreferenceDefault.defaultWindowWidth

    @AppStorage(
        AppPreferenceKey.defaultWindowHeight
    ) private var defaultWindowHeight = AppPreferenceDefault.defaultWindowHeight

    @AppStorage(
        AppPreferenceKey.windowBackgroundVisibility
    ) private var windowBackgroundVisibility = AppPreferenceDefault.windowBackgroundVisibility

    @AppStorage(
        AppPreferenceKey.windowBackgroundColorLightHex
    ) private var windowBackgroundColorLightHex = AppPreferenceDefault.windowBackgroundColorLightHex

    @AppStorage(
        AppPreferenceKey.windowBackgroundColorDarkHex
    ) private var windowBackgroundColorDarkHex = AppPreferenceDefault.windowBackgroundColorDarkHex

    @AppStorage(
        AppPreferenceKey.automaticUpdateCheckEnabled
    ) private var automaticUpdateCheckEnabled = AppPreferenceDefault.automaticUpdateCheckEnabled

    @AppStorage(
        AppPreferenceKey.syntaxHighlightingEnabled
    ) private var syntaxHighlightingEnabled = AppPreferenceDefault.syntaxHighlightingEnabled

    @AppStorage(
        AppPreferenceKey.syntaxHighlightingTheme
    ) private var syntaxHighlightingThemeRawValue = AppPreferenceDefault.syntaxHighlightingTheme

    @AppStorage(
        AppPreferenceKey.documentTypeface
    ) private var documentTypefaceRawValue = AppPreferenceDefault.documentTypeface

    @AppStorage(
        AppPreferenceKey.documentDensity
    ) private var documentDensityRawValue = AppPreferenceDefault.documentDensity

    @AppStorage(
        AppPreferenceKey.toolbarButtonSize
    ) private var toolbarButtonSizeRawValue = AppPreferenceDefault.toolbarButtonSize

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focusedWindowSizeField: WindowSizeFieldFocus?

    /// Selected Settings tab.
    @State private var selectedTab: SettingsTab = .general

    /// Available app options for default Markdown viewer selection.
    @State private var markdownViewerOptions: [AppRouting.MarkdownViewerAppOption] = []

    /// Selected bundle identifier for default Markdown viewer.
    @State private var selectedMarkdownViewerBundleID = ""

    /// Available app options for View Source app selection.
    @State private var viewSourceAppOptions: [AppRouting.ViewSourceAppOption] = []

    /// Selected picker ID for View Source app.
    @State private var selectedViewSourceAppID = ""

    /// Selected appearance preference in General tab.
    @State private var selectedAppearancePreference: AppRouting.AppearancePreference = .system

    /// Selected toolbar button size in General tab.
    @State private var selectedToolbarButtonSizePreference: ToolbarButtonSizePreference = .small

    /// Editable text backing for default window width input.
    @State private var defaultWindowWidthInput = ""

    /// Editable text backing for default window height input.
    @State private var defaultWindowHeightInput = ""

    /// True while General-tab picker state is being synchronised from router.
    @State private var isRefreshingGeneralTabState = false

    /// Pending default-viewer bundle ID awaiting Launch Services propagation.
    @State private var pendingMarkdownViewerBundleID: String?

    /// In-flight async synchronisation task for default-viewer picker state.
    @State private var markdownViewerSelectionSyncTask: Task<Void, Never>?

    /// Suppresses one `onChange` pass for programmatic picker assignments.
    @State private var suppressNextMarkdownViewerSelectionChange = false

    /// Suppresses one `onChange` pass for programmatic View Source picker assignments.
    @State private var suppressNextViewSourceAppSelectionChange = false

    /// True when the reset-all confirmation alert should be shown.
    @State private var isShowingResetConfirmation = false

    /// True when the General-tab reset confirmation alert should be shown.
    @State private var isShowingGeneralResetConfirmation = false

    /// True when the Appearance-tab reset confirmation alert should be shown.
    @State private var isShowingAppearanceResetConfirmation = false

    /// Fixed control width used by app pickers in the General pane.
    ///
    /// Sized to fit "Quick Markdown Viewer" in full while remaining compact.
    private let generalAppPickerWidth: CGFloat = 210

    private let appearanceRowLabelWidth: CGFloat = 160

    private var selectedSyntaxHighlightTheme: SyntaxHighlightTheme {
        SyntaxHighlightTheme.resolved(from: syntaxHighlightingThemeRawValue)
    }

    private var selectedDocumentTypeface: DocumentTypeface {
        DocumentTypeface.resolved(from: documentTypefaceRawValue)
    }

    private var selectedDocumentDensity: DocumentDensity {
        DocumentDensity.resolved(from: documentDensityRawValue)
    }

    private var windowBackgroundVisibilityPercentage: Int {
        Int(round(windowBackgroundVisibility * 100))
    }

    private var defaultWindowSizeBounds: AppRouting.WindowSizeBounds {
        routing.defaultWindowSizeBoundsForSettings()
    }

    private var defaultWindowWidthRange: ClosedRange<Int> {
        defaultWindowSizeBounds.widthRange
    }

    private var defaultWindowHeightRange: ClosedRange<Int> {
        defaultWindowSizeBounds.heightRange
    }

    /// Popup options used by the default Markdown-viewer control.
    private var markdownViewerPopupOptions: [GeneralPaneAppPicker.Option] {
        var result = markdownViewerOptions.map {
            GeneralPaneAppPicker.Option(
                id: $0.id,
                title: $0.displayName,
                icon: $0.icon,
                isSeparator: false
            )
        }

        if !markdownViewerOptions.isEmpty {
            result.append(
                GeneralPaneAppPicker.Option(
                    id: "__qmv.separator.defaultViewer__",
                    title: "",
                    icon: nil,
                    isSeparator: true
                )
            )
        }

        result.append(
            GeneralPaneAppPicker.Option(
                id: Self.selectDefaultViewerOptionID,
                title: "Select…",
                icon: nil,
                isSeparator: false
            )
        )

        return result
    }

    /// Popup options used by the View Source app control.
    private var viewSourceAppPopupOptions: [GeneralPaneAppPicker.Option] {
        var result = viewSourceAppOptions.map {
            GeneralPaneAppPicker.Option(
                id: $0.id,
                title: $0.displayName,
                icon: $0.icon,
                isSeparator: false
            )
        }

        if !viewSourceAppOptions.isEmpty {
            result.append(
                GeneralPaneAppPicker.Option(
                    id: "__qmv.separator.viewSource__",
                    title: "",
                    icon: nil,
                    isSeparator: true
                )
            )
        }

        result.append(
            GeneralPaneAppPicker.Option(
                id: Self.selectViewSourceAppOptionID,
                title: "Select…",
                icon: nil,
                isSeparator: false
            )
        )

        return result
    }

    private var lightBackgroundColourBinding: Binding<Color> {
        Binding(
            get: {
                let fallbackColor = nsColor(fromHex: AppPreferenceDefault.windowBackgroundColorLightHex)
                    ?? NSColor.windowBackgroundColor
                let color = nsColor(fromHex: windowBackgroundColorLightHex) ?? fallbackColor
                return Color(nsColor: color)
            },
            set: { newColor in
                windowBackgroundColorLightHex = hexString(from: NSColor(newColor))
            }
        )
    }

    private var darkBackgroundColourBinding: Binding<Color> {
        Binding(
            get: {
                let fallbackColor = nsColor(fromHex: AppPreferenceDefault.windowBackgroundColorDarkHex)
                    ?? NSColor.windowBackgroundColor
                let color = nsColor(fromHex: windowBackgroundColorDarkHex) ?? fallbackColor
                return Color(nsColor: color)
            },
            set: { newColor in
                windowBackgroundColorDarkHex = hexString(from: NSColor(newColor))
            }
        )
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Form {
                LabeledContent("Default Markdown viewer:") {
                    GeneralPaneAppPicker(
                        selectionID: $selectedMarkdownViewerBundleID,
                        options: markdownViewerPopupOptions
                    )
                    .frame(width: generalAppPickerWidth, height: 24)
                    .disabled(markdownViewerOptions.isEmpty)
                }

                LabeledContent("View source with:") {
                    GeneralPaneAppPicker(
                        selectionID: $selectedViewSourceAppID,
                        options: viewSourceAppPopupOptions
                    )
                    .frame(width: generalAppPickerWidth, height: 24)
                    .disabled(viewSourceAppOptions.isEmpty)
                }

                LabeledContent("Updates:") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(
                            "Automatically check for updates",
                            isOn: $automaticUpdateCheckEnabled
                        )

                        Text("When enabled, Quick Markdown Viewer automatically contacts GitHub to check for updates.")
                            .foregroundStyle(.secondary)
                            .font(.footnote)
                    }
                }

                LabeledContent("Reset:") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Press this button to restore the default settings in this pane only")

                        Button("Reset General Settings") {
                            isShowingGeneralResetConfirmation = true
                        }
                    }
                }
                .padding(.top, 6)

                LabeledContent("Reset all settings:") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Press this button to restore the default settings across all panes")

                        Button("Reset All Settings") {
                            isShowingResetConfirmation = true
                        }
                    }
                }
                .padding(.top, 6)
            }
            .padding(20)
            .tabItem {
                Label("General", systemImage: "gearshape")
            }
            .tag(SettingsTab.general)

            Form {
                VStack(alignment: .leading, spacing: 0) {
                    appearancePaneRow("Appearance mode:", alignment: .center) {
                        Picker("", selection: $selectedAppearancePreference) {
                            ForEach(AppRouting.AppearancePreference.allCases) { option in
                                Text(option.displayName)
                                    .tag(option)
                            }
                        }
                        .labelsHidden()
                    }
                    .padding(.vertical, 4)

                    appearancePaneRow("Background colour:", alignment: .center) {
                        HStack(spacing: 8) {
                            Text("Light:")
                                .foregroundStyle(.secondary)
                            ColorPicker("Light", selection: lightBackgroundColourBinding)
                                .labelsHidden()

                            Color.clear
                                .frame(width: 12, height: 1)

                            Text("Dark:")
                                .foregroundStyle(.secondary)
                            ColorPicker("Dark", selection: darkBackgroundColourBinding)
                                .labelsHidden()
                        }
                    }
                    .padding(.vertical, 4)

                    appearancePaneRow("Visible background:") {
                        HStack(spacing: 12) {
                            Slider(
                                value: $windowBackgroundVisibility,
                                in: 0...1
                            ) {
                                EmptyView()
                            } minimumValueLabel: {
                                Text("0%")
                                    .foregroundStyle(.secondary)
                            } maximumValueLabel: {
                                Text("100%")
                                    .foregroundStyle(.secondary)
                            }

                            Text("\(windowBackgroundVisibilityPercentage)%")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .padding(.vertical, 4)

                    appearancePaneRow("") {
                        Text("Set visible background to 0% to make rendered Markdown fill the full window.")
                            .foregroundStyle(.secondary)
                            .font(.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)

                    appearancePaneRow("Default window size:", alignment: .center) {
                        HStack(spacing: 8) {
                            HStack(spacing: 8) {
                                Text("Width:")
                                    .foregroundStyle(.secondary)
                                TextField("", text: $defaultWindowWidthInput)
                                    .frame(width: 52)
                                    .multilineTextAlignment(.trailing)
                                    .focused($focusedWindowSizeField, equals: .width)
                                    .onSubmit {
                                        commitDefaultWindowWidthInput()
                                    }
                                Text("pt")
                                    .foregroundStyle(.secondary)
                            }

                            Color.clear
                                .frame(width: 12, height: 1)

                            HStack(spacing: 8) {
                                Text("Height:")
                                    .foregroundStyle(.secondary)
                                TextField("", text: $defaultWindowHeightInput)
                                    .frame(width: 52)
                                    .multilineTextAlignment(.trailing)
                                    .focused($focusedWindowSizeField, equals: .height)
                                    .onSubmit {
                                        commitDefaultWindowHeightInput()
                                    }
                                Text("pt")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)

                    appearancePaneRow("") {
                        Text("Width range: \(defaultWindowWidthRange.lowerBound)–\(defaultWindowWidthRange.upperBound) pt · Height range: \(defaultWindowHeightRange.lowerBound)–\(defaultWindowHeightRange.upperBound) pt")
                            .foregroundStyle(.secondary)
                            .font(.footnote)
                    }
                    .padding(.top, 2)
                    .padding(.bottom, 4)

                    appearancePaneRow("Toolbar button size:", alignment: .center) {
                        Picker("", selection: $selectedToolbarButtonSizePreference) {
                            ForEach(ToolbarButtonSizePreference.allCases) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                        .labelsHidden()
                    }
                    .padding(.vertical, 4)

                    appearancePaneRow("Document style:", alignment: .center) {
                        HStack(spacing: 16) {
                            HStack(spacing: 2) {
                                Text("Typeface:")
                                    .foregroundStyle(.secondary)
                                Picker("", selection: $documentTypefaceRawValue) {
                                    ForEach(DocumentTypeface.allCases) { typeface in
                                        Text(typeface.displayName).tag(typeface.rawValue)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 140)
                            }

                            HStack(spacing: 2) {
                                Text("Density:")
                                    .foregroundStyle(.secondary)
                                Picker("", selection: $documentDensityRawValue) {
                                    ForEach(DocumentDensity.allCases) { density in
                                        Text(density.displayName).tag(density.rawValue)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 120)
                            }
                        }
                    }
                    .padding(.vertical, 4)

                    appearancePaneRow("Syntax highlighting:") {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Highlight code blocks", isOn: $syntaxHighlightingEnabled)

                            HStack(spacing: 2) {
                                Text("Theme:")
                                    .foregroundStyle(.secondary)
                                Picker("", selection: $syntaxHighlightingThemeRawValue) {
                                    ForEach(SyntaxHighlightTheme.allCases) { theme in
                                        Text(theme.displayName).tag(theme.rawValue)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 170)
                                .disabled(!syntaxHighlightingEnabled)
                            }
                        }
                    }
                    .padding(.vertical, 4)

                    appearancePaneRow("") {
                        if selectedTab == .appearance {
                            SyntaxHighlightPreviewPanel(
                                theme: selectedSyntaxHighlightTheme,
                                typeface: selectedDocumentTypeface,
                                density: selectedDocumentDensity,
                                isHighlightingEnabled: syntaxHighlightingEnabled,
                                isDarkMode: colorScheme == .dark
                            )
                        }
                    }
                    .padding(.vertical, 2)

                    appearancePaneRow("Reset:") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Press this button to restore the default settings in this pane only")

                            Button("Reset Appearance Settings") {
                                isShowingAppearanceResetConfirmation = true
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(20)
            .alert("Reset Appearance settings?", isPresented: $isShowingAppearanceResetConfirmation) {
                Button("Cancel", role: .cancel) {}
            Button("Reset Appearance Settings", role: .destructive) {
                resetBackgroundSettingsToDefaults()
            }
        } message: {
            Text("This restores default settings in the Appearance pane only. This action cannot be undone.")
        }
            .tabItem {
                Label("Appearance", systemImage: "paintpalette")
            }
            .tag(SettingsTab.appearance)
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 420)
        .onAppear {
            refreshGeneralTabState()
            clampStoredDefaultWindowSizeToCurrentBounds()
            syncWindowSizeInputFieldsFromStoredValues()
        }
        .onChange(of: selectedMarkdownViewerBundleID) { newBundleID in
            if suppressNextMarkdownViewerSelectionChange {
                suppressNextMarkdownViewerSelectionChange = false
                return
            }

            guard !isRefreshingGeneralTabState else {
                return
            }

            guard !newBundleID.isEmpty else {
                return
            }

            if newBundleID == Self.selectDefaultViewerOptionID {
                if let selectedBundleID = routing.promptForDefaultMarkdownViewerSelection() {
                    applyDefaultMarkdownViewerSelection(selectedBundleID)
                }
                refreshGeneralTabState()
                return
            }

            applyDefaultMarkdownViewerSelection(newBundleID)
        }
        .onChange(of: selectedViewSourceAppID) { newSelectionID in
            if suppressNextViewSourceAppSelectionChange {
                suppressNextViewSourceAppSelectionChange = false
                return
            }

            guard !isRefreshingGeneralTabState else {
                return
            }

            guard !newSelectionID.isEmpty else {
                return
            }

            if newSelectionID == Self.selectViewSourceAppOptionID {
                if let selection = routing.promptForViewSourceAppSelection() {
                    routing.setViewSourceAppForSettings(
                        bundleIdentifier: selection.bundleIdentifier,
                        appURL: selection.appURL
                    )
                }
                refreshGeneralTabState()
                return
            }

            routing.setViewSourceAppSelectionIDForSettings(newSelectionID)
            refreshGeneralTabState()
        }
        .onChange(of: selectedAppearancePreference) { newPreference in
            guard !isRefreshingGeneralTabState else {
                return
            }

            routing.setAppearancePreferenceForSettings(newPreference)
        }
        .onChange(of: selectedToolbarButtonSizePreference) { newPreference in
            guard !isRefreshingGeneralTabState else {
                return
            }

            toolbarButtonSizeRawValue = newPreference.rawValue
            routing.setToolbarButtonSizePreferenceForSettings(newPreference)
        }
        .onChange(of: routing.appearancePreferenceRevision) { _ in
            guard !isRefreshingGeneralTabState else {
                return
            }
            selectedAppearancePreference = routing.appearancePreferenceForSettings()
        }
        .onChange(of: routing.toolbarButtonSizePreferenceRevision) { _ in
            guard !isRefreshingGeneralTabState else {
                return
            }
            selectedToolbarButtonSizePreference = routing.toolbarButtonSizePreferenceForSettings()
            toolbarButtonSizeRawValue = selectedToolbarButtonSizePreference.rawValue
        }
        .onChange(of: routing.windowSizeBoundsRevision) { _ in
            clampStoredDefaultWindowSizeToCurrentBounds()
            syncWindowSizeInputFieldsFromStoredValues(force: true)
        }
        .onChange(of: focusedWindowSizeField) { newFocus in
            if newFocus != .width {
                commitDefaultWindowWidthInput()
            }

            if newFocus != .height {
                commitDefaultWindowHeightInput()
            }
        }
        .onChange(of: defaultWindowWidth) { _ in
            syncWindowSizeInputFieldsFromStoredValues()
        }
        .onChange(of: defaultWindowHeight) { _ in
            syncWindowSizeInputFieldsFromStoredValues()
        }
        .alert("Reset General settings?", isPresented: $isShowingGeneralResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset General Settings", role: .destructive) {
                resetGeneralSettingsToDefaults()
            }
        } message: {
            Text("This restores default settings in the General pane only. This action cannot be undone.")
        }
        .alert("Reset all settings?", isPresented: $isShowingResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset All Settings", role: .destructive) {
                resetAllSettingsToDefaults()
            }
        } message: {
            Text("This restores default settings across all panes. This action cannot be undone.")
        }
    }

    /// Restores all settings currently exposed in the v1.0.6 Settings window.
    ///
    /// This is intentionally global (all tabs), not scoped to one tab.
    private func resetAllSettingsToDefaults() {
        resetGeneralSettingsToDefaults()
        resetBackgroundSettingsToDefaults()
        routing.resetAppearancePreferenceToSystemDefault()
        refreshGeneralTabState()
    }

    /// Restores only settings shown in the General tab.
    private func resetGeneralSettingsToDefaults() {
        automaticUpdateCheckEnabled = AppPreferenceDefault.automaticUpdateCheckEnabled
        routing.resetViewSourceAppPreferenceToSystemDefault()
        if let ownBundleIdentifier = Bundle.main.bundleIdentifier {
            applyDefaultMarkdownViewerSelection(ownBundleIdentifier)
        } else {
            refreshGeneralTabState()
        }
    }

    /// Restores only settings shown in the Appearance pane.
    private func resetBackgroundSettingsToDefaults() {
        routing.resetAppearancePreferenceToSystemDefault()
        selectedAppearancePreference = routing.appearancePreferenceForSettings()
        windowBackgroundVisibility = AppPreferenceDefault.windowBackgroundVisibility
        windowBackgroundColorLightHex = AppPreferenceDefault.windowBackgroundColorLightHex
        windowBackgroundColorDarkHex = AppPreferenceDefault.windowBackgroundColorDarkHex
        syntaxHighlightingEnabled = AppPreferenceDefault.syntaxHighlightingEnabled
        syntaxHighlightingThemeRawValue = AppPreferenceDefault.syntaxHighlightingTheme
        documentTypefaceRawValue = AppPreferenceDefault.documentTypeface
        documentDensityRawValue = AppPreferenceDefault.documentDensity
        defaultWindowWidth = AppPreferenceDefault.defaultWindowWidth
        defaultWindowHeight = AppPreferenceDefault.defaultWindowHeight
        clampStoredDefaultWindowSizeToCurrentBounds()
        focusedWindowSizeField = nil
        syncWindowSizeInputFieldsFromStoredValues(force: true)
        toolbarButtonSizeRawValue = AppPreferenceDefault.toolbarButtonSize
        selectedToolbarButtonSizePreference = ToolbarButtonSizePreference.resolved(
            from: AppPreferenceDefault.toolbarButtonSize
        )
        routing.setToolbarButtonSizePreferenceForSettings(selectedToolbarButtonSizePreference)
    }

    /// Refreshes General-tab controls from current system/app state.
    private func refreshGeneralTabState() {
        isRefreshingGeneralTabState = true
        defer { isRefreshingGeneralTabState = false }

        let options = routing.markdownViewerAppOptions()
        markdownViewerOptions = options

        let defaultBundleID = routing.defaultMarkdownViewerBundleIdentifier() ?? options.first?.id ?? ""
        let shouldApplyDefaultSelection: Bool
        if let pendingBundleID = pendingMarkdownViewerBundleID {
            if defaultBundleID == pendingBundleID {
                pendingMarkdownViewerBundleID = nil
                shouldApplyDefaultSelection = true
            } else {
                shouldApplyDefaultSelection = false
            }
        } else {
            shouldApplyDefaultSelection = true
        }

        if shouldApplyDefaultSelection, selectedMarkdownViewerBundleID != defaultBundleID {
            setSelectedMarkdownViewerBundleIDSilently(defaultBundleID)
        }

        viewSourceAppOptions = routing.viewSourceAppOptions()
        let preferredViewSourceSelectionID = routing.viewSourceAppSelectionIDForSettings()
        let resolvedViewSourceSelectionID: String
        if viewSourceAppOptions.contains(where: { $0.id == preferredViewSourceSelectionID }) {
            resolvedViewSourceSelectionID = preferredViewSourceSelectionID
        } else {
            resolvedViewSourceSelectionID = viewSourceAppOptions.first?.id ?? ""
        }

        if selectedViewSourceAppID != resolvedViewSourceSelectionID {
            setSelectedViewSourceAppIDSilently(resolvedViewSourceSelectionID)
        }

        selectedAppearancePreference = routing.appearancePreferenceForSettings()
        selectedToolbarButtonSizePreference = routing.toolbarButtonSizePreferenceForSettings()
        toolbarButtonSizeRawValue = selectedToolbarButtonSizePreference.rawValue
    }

    /// Applies a new default-viewer selection and synchronises picker state after
    /// asynchronous Launch Services confirmation/propagation.
    private func applyDefaultMarkdownViewerSelection(_ bundleID: String) {
        markdownViewerSelectionSyncTask?.cancel()
        let currentDefaultBundleID =
            routing.defaultMarkdownViewerBundleIdentifier()
            ?? markdownViewerOptions.first?.id
            ?? ""
        setSelectedMarkdownViewerBundleIDSilently(currentDefaultBundleID)
        pendingMarkdownViewerBundleID = bundleID
        routing.setDefaultMarkdownViewer(bundleIdentifier: bundleID)
        refreshGeneralTabState()

        markdownViewerSelectionSyncTask = Task { @MainActor in
            defer { markdownViewerSelectionSyncTask = nil }

            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else {
                    return
                }
                refreshGeneralTabState()
                if pendingMarkdownViewerBundleID == nil {
                    return
                }
            }

            // If the system did not accept/apply the requested handler, settle
            // to the current effective handler rather than keeping stale UI.
            pendingMarkdownViewerBundleID = nil
            refreshGeneralTabState()
        }
    }

    /// Updates picker selection without triggering its change handler.
    private func setSelectedMarkdownViewerBundleIDSilently(_ bundleID: String) {
        guard selectedMarkdownViewerBundleID != bundleID else {
            return
        }

        suppressNextMarkdownViewerSelectionChange = true
        selectedMarkdownViewerBundleID = bundleID
    }

    /// Updates View Source picker selection without triggering its change handler.
    private func setSelectedViewSourceAppIDSilently(_ selectionID: String) {
        guard selectedViewSourceAppID != selectionID else {
            return
        }

        suppressNextViewSourceAppSelectionChange = true
        selectedViewSourceAppID = selectionID
    }

    /// Commits and clamps one width entry from the editable text field.
    private func commitDefaultWindowWidthInput() {
        let trimmed = defaultWindowWidthInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let parsedValue = Int(trimmed) else {
            defaultWindowWidthInput = "\(defaultWindowWidth)"
            return
        }

        let clampedValue = min(max(parsedValue, defaultWindowWidthRange.lowerBound), defaultWindowWidthRange.upperBound)
        defaultWindowWidth = clampedValue
        defaultWindowWidthInput = "\(clampedValue)"
    }

    /// Commits and clamps one height entry from the editable text field.
    private func commitDefaultWindowHeightInput() {
        let trimmed = defaultWindowHeightInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let parsedValue = Int(trimmed) else {
            defaultWindowHeightInput = "\(defaultWindowHeight)"
            return
        }

        let clampedValue = min(max(parsedValue, defaultWindowHeightRange.lowerBound), defaultWindowHeightRange.upperBound)
        defaultWindowHeight = clampedValue
        defaultWindowHeightInput = "\(clampedValue)"
    }

    /// Clamps persisted default window size to the current dynamic bounds.
    private func clampStoredDefaultWindowSizeToCurrentBounds() {
        let clampedWidth = min(
            max(defaultWindowWidth, defaultWindowWidthRange.lowerBound),
            defaultWindowWidthRange.upperBound
        )
        if clampedWidth != defaultWindowWidth {
            defaultWindowWidth = clampedWidth
        }

        let clampedHeight = min(
            max(defaultWindowHeight, defaultWindowHeightRange.lowerBound),
            defaultWindowHeightRange.upperBound
        )
        if clampedHeight != defaultWindowHeight {
            defaultWindowHeight = clampedHeight
        }
    }

    /// Keeps editable width/height text in sync with persisted values.
    private func syncWindowSizeInputFieldsFromStoredValues(force: Bool = false) {
        if force || focusedWindowSizeField != .width {
            defaultWindowWidthInput = "\(defaultWindowWidth)"
        }

        if force || focusedWindowSizeField != .height {
            defaultWindowHeightInput = "\(defaultWindowHeight)"
        }
    }

    /// Shared row layout used by Appearance pane for fixed right-aligned labels.
    @ViewBuilder
    private func appearancePaneRow<Content: View>(
        _ title: String,
        alignment: VerticalAlignment = .top,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: alignment, spacing: 12) {
            Text(title)
                .frame(width: appearanceRowLabelWidth, alignment: .trailing)
                .fixedSize(horizontal: true, vertical: false)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Parses one `#RRGGBB` colour string into an `NSColor`.
    private func nsColor(fromHex hex: String) -> NSColor? {
        let value = hex
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let sanitized = value.hasPrefix("#") ? String(value.dropFirst()) : value

        guard sanitized.count == 6,
              let rgb = UInt64(sanitized, radix: 16) else {
            return nil
        }

        let red = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
        let green = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
        let blue = CGFloat(rgb & 0x0000FF) / 255.0
        return NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1.0)
    }

    /// Converts any `NSColor` into a normalised `#RRGGBB` value.
    private func hexString(from color: NSColor) -> String {
        let converted = color.usingColorSpace(.deviceRGB) ?? color
        let red = Int(round(converted.redComponent * 255))
        let green = Int(round(converted.greenComponent * 255))
        let blue = Int(round(converted.blueComponent * 255))

        return String(
            format: "#%02X%02X%02X",
            max(0, min(255, red)),
            max(0, min(255, green)),
            max(0, min(255, blue))
        )
    }
}

/// Native popup picker used in the General pane.
///
/// Using one AppKit-backed control for both app pickers guarantees identical
/// visual sizing (width/height/font) and alignment.
private struct GeneralPaneAppPicker: NSViewRepresentable {
    struct Option: Equatable {
        let id: String
        let title: String
        let icon: NSImage?
        let isSeparator: Bool
    }

    @Binding var selectionID: String
    let options: [Option]

    func makeCoordinator() -> Coordinator {
        Coordinator(selectionID: $selectionID)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.autoenablesItems = false
        button.controlSize = .regular
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionDidChange(_:))
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let coordinator = context.coordinator
        coordinator.isUpdating = true
        defer { coordinator.isUpdating = false }

        if coordinator.cachedOptions != options {
            coordinator.cachedOptions = options
            button.removeAllItems()
            let menu = NSMenu()
            for option in options {
                if option.isSeparator {
                    menu.addItem(.separator())
                    continue
                }

                let item = NSMenuItem(title: option.title, action: nil, keyEquivalent: "")
                item.representedObject = option.id
                if let icon = option.icon {
                    let sizedIcon = icon.copy() as? NSImage ?? icon
                    sizedIcon.size = NSSize(width: 16, height: 16)
                    item.image = sizedIcon
                }
                menu.addItem(item)
            }
            button.menu = menu
        }

        if let targetItem = button.menu?.items.first(where: {
            ($0.representedObject as? String) == selectionID
        }) {
            button.select(targetItem)
        } else if let fallbackItem = button.menu?.items.first(where: {
            ($0.representedObject as? String) != nil
        }) {
            button.select(fallbackItem)
        } else {
            button.select(nil)
        }
    }

    final class Coordinator: NSObject {
        @Binding var selectionID: String
        var cachedOptions: [Option] = []
        var isUpdating = false

        init(selectionID: Binding<String>) {
            _selectionID = selectionID
        }

        @objc
        func selectionDidChange(_ sender: NSPopUpButton) {
            guard !isUpdating else {
                return
            }
            guard let selectedID = sender.selectedItem?.representedObject as? String else {
                return
            }
            selectionID = selectedID
        }
    }
}

/// Compact syntax-highlighting preview shown in the Appearance pane.
private struct SyntaxHighlightPreviewPanel: View {
    let theme: SyntaxHighlightTheme
    let typeface: DocumentTypeface
    let density: DocumentDensity
    let isHighlightingEnabled: Bool
    let isDarkMode: Bool
    private let previewHeight: CGFloat = 66
    private let previewWidth: CGFloat = 273
    private let previewCornerRadius: CGFloat = 10

    private var previewBackgroundColor: Color {
        if isDarkMode {
            return Color(red: 0x25 / 255.0, green: 0x2B / 255.0, blue: 0x32 / 255.0)
        }
        return Color(red: 0xF2 / 255.0, green: 0xF5 / 255.0, blue: 0xF8 / 255.0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isHighlightingEnabled {
                SyntaxHighlightPreviewWebView(
                    configuration: SyntaxHighlightPreviewConfiguration(
                        theme: theme,
                        typeface: typeface,
                        density: density,
                        isHighlightingEnabled: isHighlightingEnabled,
                        isDarkMode: isDarkMode
                    )
                )
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: previewCornerRadius, style: .continuous)
                        .fill(previewBackgroundColor)
                    Text("Theme preview")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                }
            }
        }
        .frame(width: previewWidth, height: previewHeight)
        .clipShape(RoundedRectangle(cornerRadius: previewCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: previewCornerRadius, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
        )
    }
}

/// Equatable configuration for settings preview rendering.
private struct SyntaxHighlightPreviewConfiguration: Equatable {
    let theme: SyntaxHighlightTheme
    let typeface: DocumentTypeface
    let density: DocumentDensity
    let isHighlightingEnabled: Bool
    let isDarkMode: Bool
}

/// Native web preview so settings reflect the exact bundled highlight theme CSS.
private struct SyntaxHighlightPreviewWebView: NSViewRepresentable {
    let configuration: SyntaxHighlightPreviewConfiguration

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.setAccessibilityElement(false)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.lastConfiguration != configuration else {
            return
        }

        context.coordinator.lastConfiguration = configuration
        let html = makeHTML(configuration: configuration)
        webView.loadHTMLString(html, baseURL: nil)
    }

    private func makeHTML(configuration: SyntaxHighlightPreviewConfiguration) -> String {
        let themeCSS = loadThemeCSS(theme: configuration.theme, isDarkMode: configuration.isDarkMode)
        let highlightJavaScript = configuration.isHighlightingEnabled ? loadHighlightJavaScript() : ""
        let textColor = configuration.isDarkMode ? "#E8EDF2" : "#1F2933"
        let codeBackground = configuration.isDarkMode ? "#252B32" : "#F2F5F8"
        let codeBorder = configuration.isDarkMode ? "#36404A" : "#DDE3EA"
        let bodyBackground = codeBackground
        let snippetSource = [
            "import Foundation",
            "let message = \"Hello, Markdown!\"",
            "print(message)"
        ].joined(separator: "\n")
        let escapedSnippet = escapeHTML(snippetSource)
        let codeClass = configuration.isHighlightingEnabled ? "hljs language-swift" : ""
        let previewTypefaceClass = "qmv-typeface-\(configuration.typeface.rawValue)"
        let previewDensityClass = "qmv-density-\(configuration.density.rawValue)"
        let highlightBootstrapScript = configuration.isHighlightingEnabled ? """
            <script>
              \(highlightJavaScript)
            </script>
            <script>
              (function () {
                const code = document.getElementById("preview-code");
                if (window.hljs && code) {
                  window.hljs.highlightElement(code);
                }
              })();
            </script>
            """ : ""

        return """
        <!doctype html>
        <html>
          <head>
            <meta charset="utf-8" />
            <style>
              \(themeCSS)
              html, body {
                margin: 0;
                padding: 0;
                height: 100%;
                background: \(bodyBackground);
                overflow: hidden;
              }
              body {
                font: 13px/1.3 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
                color: \(textColor);
              }
              .preview {
                margin: 0;
                padding: 8px 10px 5px 10px;
                height: 100%;
                box-sizing: border-box;
                background: \(codeBackground);
                border: 1px solid \(codeBorder);
                border-radius: 10px;
                overflow: hidden;
              }
              pre {
                margin: 0;
                white-space: pre;
                overflow: hidden;
              }
              code {
                display: block;
                font: 13px/1.3 "SF Mono", "SFMono-Regular", Menlo, Monaco, Consolas, "Liberation Mono", monospace;
              }
              pre code.hljs,
              code.hljs {
                background: transparent !important;
                padding: 0 !important;
              }
              pre code.hljs *,
              code.hljs * {
                font-style: normal !important;
                font-weight: inherit !important;
              }
            </style>
          </head>
          <body>
            <pre class="preview \(previewTypefaceClass) \(previewDensityClass)"><code id="preview-code" class="\(codeClass)">\(escapedSnippet)</code></pre>
            \(highlightBootstrapScript)
          </body>
        </html>
        """
    }

    private static let themeResourceNames: [String] = [
        "highlight-github-dark.min",
        "highlight-github.min",
        "highlight-vs2015.min",
        "highlight-vs.min",
        "highlight-atom-one-dark.min",
        "highlight-atom-one-light.min",
        "highlight-stackoverflow-dark.min",
        "highlight-stackoverflow-light.min"
    ]

    private static let cachedThemeCSSByResourceName: [String: String] = {
        Dictionary(
            uniqueKeysWithValues: themeResourceNames.map { resourceName in
                (resourceName, loadBundledResource(named: resourceName, ext: "css"))
            }
        )
    }()

    private static let cachedHighlightJavaScript: String = {
        loadBundledResource(named: "highlight.min", ext: "js")
    }()

    private static func loadBundledResource(named name: String, ext: String) -> String {
        let url = Bundle.main.url(
            forResource: name,
            withExtension: ext,
            subdirectory: "Web"
        ) ?? Bundle.main.url(forResource: name, withExtension: ext)

        guard let url else {
            return ""
        }

        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func loadThemeCSS(theme: SyntaxHighlightTheme, isDarkMode: Bool) -> String {
        let resourceName: String

        switch (theme, isDarkMode) {
        case (.github, true):
            resourceName = "highlight-github-dark.min"
        case (.github, false):
            resourceName = "highlight-github.min"
        case (.vscode, true):
            resourceName = "highlight-vs2015.min"
        case (.vscode, false):
            resourceName = "highlight-vs.min"
        case (.atomOne, true):
            resourceName = "highlight-atom-one-dark.min"
        case (.atomOne, false):
            resourceName = "highlight-atom-one-light.min"
        case (.stackOverflow, true):
            resourceName = "highlight-stackoverflow-dark.min"
        case (.stackOverflow, false):
            resourceName = "highlight-stackoverflow-light.min"
        }

        return Self.cachedThemeCSSByResourceName[resourceName] ?? ""
    }

    private func loadHighlightJavaScript() -> String {
        Self.cachedHighlightJavaScript
    }

    private func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    final class Coordinator: NSObject {
        var lastConfiguration: SyntaxHighlightPreviewConfiguration?
    }
}
