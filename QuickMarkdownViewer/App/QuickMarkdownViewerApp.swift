import SwiftUI
import Darwin

/// User-default keys backing app-level settings.
enum AppPreferenceKey {
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
}

/// Default values for app-level settings.
enum AppPreferenceDefault {
    /// v1.0.6 default: about half the legacy v1.0.5 background framing.
    static let windowBackgroundVisibility = 0.5

    /// Default selected light-mode background colour.
    static let windowBackgroundColorLightHex = "#F6F5F2"

    /// Default selected dark-mode background colour.
    static let windowBackgroundColorDarkHex = "#16181B"

    /// Default update-check mode: manual only.
    static let automaticUpdateCheckEnabled = false
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

    /// Tabs shown in the Settings window.
    private enum SettingsTab: Hashable {
        case general
        case appearance
    }

    /// Shared app router used for update checks and appearance resets.
    @ObservedObject var routing: AppRouting

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

    /// Selected Settings tab.
    @State private var selectedTab: SettingsTab = .general

    /// Available app options for default Markdown viewer selection.
    @State private var markdownViewerOptions: [AppRouting.MarkdownViewerAppOption] = []

    /// Selected bundle identifier for default Markdown viewer.
    @State private var selectedMarkdownViewerBundleID = ""

    /// Selected appearance preference in General tab.
    @State private var selectedAppearancePreference: AppRouting.AppearancePreference = .system

    /// True while General-tab picker state is being synchronised from router.
    @State private var isRefreshingGeneralTabState = false

    /// Pending default-viewer bundle ID awaiting Launch Services propagation.
    @State private var pendingMarkdownViewerBundleID: String?

    /// In-flight async synchronisation task for default-viewer picker state.
    @State private var markdownViewerSelectionSyncTask: Task<Void, Never>?

    /// Suppresses one `onChange` pass for programmatic picker assignments.
    @State private var suppressNextMarkdownViewerSelectionChange = false

    /// True when the reset-all confirmation alert should be shown.
    @State private var isShowingResetConfirmation = false

    /// True when the General-tab reset confirmation alert should be shown.
    @State private var isShowingGeneralResetConfirmation = false

    /// True when the Appearance-tab reset confirmation alert should be shown.
    @State private var isShowingAppearanceResetConfirmation = false

    private let appearanceRowLabelWidth: CGFloat = 160

    private var windowBackgroundVisibilityPercentage: Int {
        Int(round(windowBackgroundVisibility * 100))
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
                Picker("Default Markdown viewer:", selection: $selectedMarkdownViewerBundleID) {
                    ForEach(markdownViewerOptions) { option in
                        Label {
                            Text(option.displayName)
                        } icon: {
                            Image(nsImage: option.icon)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 16, height: 16)
                        }
                        .tag(option.id)
                    }

                    if !markdownViewerOptions.isEmpty {
                        Divider()
                    }

                    Text("Select…")
                        .tag(Self.selectDefaultViewerOptionID)
                }
                .disabled(markdownViewerOptions.isEmpty)

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

                    appearancePaneRow("Background colour:") {
                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Light")
                                ColorPicker("Light", selection: lightBackgroundColourBinding)
                                    .labelsHidden()
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Dark")
                                ColorPicker("Dark", selection: darkBackgroundColourBinding)
                                    .labelsHidden()
                            }
                        }
                    }
                    .padding(.vertical, 4)

                    appearancePaneRow("Reset:") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Press this button to restore the default settings in this pane only")

                            Button("Reset Appearance Settings") {
                                isShowingAppearanceResetConfirmation = true
                            }
                        }
                    }
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
        .onChange(of: selectedAppearancePreference) { newPreference in
            guard !isRefreshingGeneralTabState else {
                return
            }

            routing.setAppearancePreferenceForSettings(newPreference)
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
        if let ownBundleIdentifier = Bundle.main.bundleIdentifier {
            applyDefaultMarkdownViewerSelection(ownBundleIdentifier)
        } else {
            refreshGeneralTabState()
        }
    }

    /// Restores only window-background controls in the Appearance tab.
    private func resetBackgroundSettingsToDefaults() {
        windowBackgroundVisibility = AppPreferenceDefault.windowBackgroundVisibility
        windowBackgroundColorLightHex = AppPreferenceDefault.windowBackgroundColorLightHex
        windowBackgroundColorDarkHex = AppPreferenceDefault.windowBackgroundColorDarkHex
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

        selectedAppearancePreference = routing.appearancePreferenceForSettings()
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
