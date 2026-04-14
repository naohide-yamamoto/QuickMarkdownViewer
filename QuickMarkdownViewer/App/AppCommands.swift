import AppKit
import SwiftUI

@available(macOS 14.0, *)
private struct SettingsMenuButton: View {
    var body: some View {
        SettingsLink {
            Label("Settings…", systemImage: "gearshape")
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}

/// Defines app-wide menu commands.
///
/// QuickMarkdownViewer intentionally exposes a tiny command surface to preserve
/// a utility-style reading experience.
struct AppCommands: Commands {
    /// Router used to trigger app-level actions from menu commands.
    @ObservedObject var routing: AppRouting

    /// Fallback settings opener for older macOS deployment targets.
    private func openSettingsWindowLegacy() {
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            _ = NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    var body: some Commands {
        // Replace "New" with "Open…" because this app is a viewer,
        // not a document editor/creator.
        CommandGroup(replacing: .newItem) {
            // Use a menu icon so File > Open mirrors standard macOS affordance.
            Button(action: {
                routing.openDocumentPanel()
            }) {
                Label("Open…", systemImage: "arrow.up.right")
            }
            .keyboardShortcut("o", modifiers: .command)

            // Provide native-style "Open Recent" behaviour even though
            // QuickMarkdownViewer uses manual window management instead of DocumentGroup.
            Menu {
                let recentURLs = routing.recentDocumentURLsForMenu()

                if recentURLs.isEmpty {
                    // Keep an icon here so the submenu remains visually
                    // consistent even when there are no entries yet.
                    Button(action: {}) {
                        Label("No Recent Documents", systemImage: "clock")
                    }
                        .disabled(true)
                } else {
                    ForEach(recentURLs, id: \.self) { recentURL in
                        // File icon mirrors native recent-document entries.
                        Button(action: {
                            routing.openRecentDocument(recentURL)
                        }) {
                            Label(recentURL.lastPathComponent, systemImage: "doc.text")
                        }
                    }

                    Divider()

                    // Trash icon matches standard "clear list" semantics.
                    Button(action: {
                        routing.clearRecentDocuments()
                    }) {
                        Label("Clear Menu", systemImage: "trash")
                    }
                }
            } label: {
                // Clock-style glyph matches the native "recent" visual language.
                Label("Open Recent", systemImage: "clock.arrow.circlepath")
            }
        }

        // Route printing through QuickMarkdownViewer's active-document command channel so
        // we can print rendered content (not raw Markdown source).
        CommandGroup(replacing: .printItem) {
            // Printer glyph mirrors the standard File > Print iconography.
            Button(action: {
                routing.printRenderedDocumentInActiveWindow()
            }) {
                Label("Print…", systemImage: "printer")
            }
            .keyboardShortcut("p", modifiers: .command)
        }

        // Add document actions that belong near print/open in the File menu.
        CommandGroup(after: .printItem) {
            // Export-specific glyph avoids confusion with Share actions.
            Button(action: {
                routing.exportRenderedPDFInActiveWindow()
            }) {
                Label("Export as PDF…", systemImage: "square.and.arrow.up.on.square")
            }

            // Plain-text document glyph signals raw Markdown source viewing.
            Button(action: {
                routing.viewSourceExternallyInActiveWindow()
            }) {
                Label("View Source", systemImage: "doc.plaintext")
            }

            Divider()

            // Keep Share as a submenu so File > Share immediately reveals
            // available services, matching standard macOS app behaviour.
            Menu {
                let shareServices = routing.shareServicesForActiveDocument()

                if shareServices.isEmpty {
                    Button("No Share Services", action: {})
                        .disabled(true)
                } else {
                    ForEach(shareServices) { entry in
                        Button(action: {
                            routing.performShareService(entry)
                        }) {
                            if let image = entry.image {
                                Label {
                                    Text(entry.title)
                                } icon: {
                                    Image(nsImage: image)
                                }
                            } else {
                                Text(entry.title)
                            }
                        }
                    }
                }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }

        // Inject a dedicated Find submenu under Edit so all find-related
        // actions are grouped in the standard macOS location: Edit > Find.
        CommandGroup(after: .textEditing) {
            Menu {
                // Magnifier icon follows system Find affordances.
                Button(action: {
                    routing.toggleFindInActiveWindow()
                }) {
                    Label("Find…", systemImage: "magnifyingglass")
                }
                .keyboardShortcut("f", modifiers: .command)

                // Down-arrow indicates moving forward through matches.
                Button(action: {
                    routing.findNextInActiveWindow()
                }) {
                    Label("Find Next", systemImage: "arrow.down")
                }
                .keyboardShortcut("g", modifiers: .command)

                // Up-arrow indicates moving backward through matches.
                Button(action: {
                    routing.findPreviousInActiveWindow()
                }) {
                    Label("Find Previous", systemImage: "arrow.up")
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])

                // `Cmd+E` follows macOS-standard selection-to-find workflow.
                Button(action: {
                    routing.useSelectionForFindInActiveWindow()
                }) {
                    Label("Use Selection for Find", systemImage: "text.cursor")
                }
                .keyboardShortcut("e", modifiers: .command)
            } label: {
                // Explicit icon keeps Find menu presentation consistent across
                // empty and loaded-document windows in current macOS builds.
                Label("Find", systemImage: "doc.text.magnifyingglass")
            }

            Divider()

            // Surface native speech actions under Edit > Speech, aligned with
            // standard macOS app menus.
            Menu {
                let canStartSpeaking = routing.canStartSpeechInActiveWindow()
                let canStopSpeaking = routing.canStopSpeechInActiveWindow()

                Button(action: {
                    routing.startSpeakingInActiveWindow()
                }) {
                    Label("Start Speaking", systemImage: "play")
                }
                .disabled(!canStartSpeaking)

                Button(action: {
                    routing.stopSpeakingInActiveWindow()
                }) {
                    Label("Stop Speaking", systemImage: "stop")
                }
                .disabled(!canStopSpeaking)
            } label: {
                Label("Speech", systemImage: "text.bubble")
            }

            Divider()
        }

        // Replace the default toolbar command group so View-menu ordering is
        // fully controlled by the custom QuickMarkdownViewer command block.
        CommandGroup(replacing: .toolbar) {
        }

        // Add standard zoom controls in the View menu for a familiar reading
        // workflow similar to Preview and other macOS document viewers.
        //
        // Anchoring after `.toolbar` places these commands under View rather
        // than Window, which matches user expectations for document viewers.
        CommandGroup(after: .toolbar) {
            // "1x" style magnifier conveys returning to true-size scale.
            Button(action: {
                routing.resetZoomInActiveWindow()
            }) {
                Label("Actual Size", systemImage: "1.magnifyingglass")
            }
            .keyboardShortcut("0", modifiers: .command)

            // Framed arrows indicate fitting content to available viewport.
            Button(action: {
                routing.zoomToFitInActiveWindow()
            }) {
                Label("Zoom to Fit", systemImage: "arrow.up.left.and.down.right.magnifyingglass")
            }
            // `Cmd+9` is a practical fit-width shortcut used by several readers
            // and browsers. In QuickMarkdownViewer it performs one-way zoom-to-fit.
            .keyboardShortcut("9", modifiers: .command)

            // Magnifier-plus mirrors native zoom-in menu semantics.
            Button(action: {
                routing.zoomInActiveWindow()
            }) {
                Label("Zoom In", systemImage: "plus.magnifyingglass")
            }
            // `=` maps to `+` with Shift on most keyboards, matching macOS
            // convention for the "Cmd + Plus" shortcut.
            .keyboardShortcut("=", modifiers: .command)

            // Magnifier-minus mirrors native zoom-out menu semantics.
            Button(action: {
                routing.zoomOutActiveWindow()
            }) {
                Label("Zoom Out", systemImage: "minus.magnifyingglass")
            }
            .keyboardShortcut("-", modifiers: .command)

            Divider()

            let _ = routing.toolbarVisibilityMenuRevision
            let isToolbarVisible = routing.isToolbarVisibleInActiveWindow()

            Button(action: {
                routing.toggleToolbarInActiveWindow()
            }) {
                Label(
                    isToolbarVisible ? "Hide Toolbar" : "Show Toolbar",
                    systemImage: isToolbarVisible ? "rectangle.compress.vertical" : "rectangle.expand.vertical"
                )
            }
            .keyboardShortcut("t", modifiers: [.command, .option])

            Button(action: {
                routing.customiseToolbarInActiveWindow()
            }) {
                Label("Customise Toolbar…", systemImage: "wrench")
            }

            Divider()

            // Half-filled circle is a stable "appearance mode toggle" glyph.
            Button(action: {
                routing.toggleLightDarkAppearance()
            }) {
                Label("Toggle Light/Dark Mode", systemImage: "circle.lefthalf.filled")
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
        }

        // Place Settings directly under About in the app menu, with explicit
        // separators so the top app-menu cluster mirrors native macOS layout.
        CommandGroup(after: .appInfo) {
            Divider()

            if #available(macOS 14.0, *) {
                SettingsMenuButton()
            } else {
                Button(action: openSettingsWindowLegacy) {
                    Label("Settings…", systemImage: "gearshape")
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            Button(action: {
                routing.checkForUpdatesManually()
            }) {
                Label("Check for Updates…", systemImage: "arrow.triangle.2.circlepath")
            }

            Divider()
        }

        // Remove the default app-settings insertion point so Settings appears
        // only in the custom location above (between About and Services).
        CommandGroup(replacing: .appSettings) {}

        // Provide a concrete Help action routed through Apple Help Book APIs.
        //
        // This keeps the menu-bar Help search field connected to searchable,
        // indexed help topics rather than a custom in-app help window.
        CommandGroup(replacing: .help) {
            Button(action: {
                routing.openHelpDocumentation()
            }) {
                Label("Quick Markdown Viewer Help", systemImage: "questionmark.circle")
            }
        }
    }
}
