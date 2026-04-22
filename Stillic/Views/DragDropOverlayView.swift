import SwiftUI

/// Lightweight visual affordance shown while a file is dragged over a window.
///
/// The overlay is purely decorative and does not intercept input.
struct DragDropOverlayView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14)
            // Dashed border keeps the cue subtle and familiar.
            .strokeBorder(
                Color.accentColor,
                style: StrokeStyle(lineWidth: 2, dash: [8, 6])
            )
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.accentColor.opacity(0.08))
            )
            .padding(20)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
