import SwiftUI
import UniformTypeIdentifiers

/// Launch/idle surface shown when no document is open.
///
/// This view supports both explicit file opening and drag-and-drop.
struct EmptyStateView: View {
    /// Action for the "Open" button.
    let onOpenRequested: () -> Void

    /// Action invoked after a valid Markdown file is dropped.
    let onFileDropped: (URL) -> Void

    /// True while drag items hover over this view.
    @State private var isDropTargeted = false

    var body: some View {
        ZStack {
            VStack(spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(.secondary)

                // Keep empty-state guidance explicit so first-time users can
                // open a file immediately without searching menus or shortcuts.
                Text("Open a Markdown file using one of these options:")
                    .font(.title3)
                    .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: 6) {
                    Text("• Drop the file here")
                    Text("• Choose File > Open (or press ⌘O)")
                    Text("• Click the folder icon in the toolbar")
                    Text("• Click the button below")
                }
                .font(.title3)
                .foregroundStyle(.secondary)

                Button("Open Markdown File…") {
                    onOpenRequested()
                }
                .padding(.top, 6)
            }
            .padding(40)

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
    }

    /// Attempts to load the first dropped file URL provider.
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let url = extractURL(from: item) else {
                return
            }

            DispatchQueue.main.async {
                onFileDropped(url.standardizedFileURL)
            }
        }

        return true
    }

    /// Extracts URL payload from common `NSItemProvider` value shapes.
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
}
