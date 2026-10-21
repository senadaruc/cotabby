import SwiftUI

/// File overview:
/// The small Cotabby affordance shown just outside a supported text field. Always renders the
/// built-in cat glyph on Cotabby's dark rounded chip.
struct FieldEdgeIconIndicatorView: View {
    // 0.7 of the original chip kept it discreet beside the input; 15% larger (2026-10-10) and then
    // 30% larger again (2026-10-21, both user requests) made it easier to see and to click, now that
    // it also floats over selected text as the rewrite wand. Glyphs scale with the chip.
    private let side: CGFloat = 21
    private let cornerRadius: CGFloat = 5
    /// Autocomplete is off in this app or window. The icon stays (it is how the user turns it back
    /// on) but fades so it reads as "Cotabby is here, but paused".
    var dimmed = false
    /// Text is selected and can be rewritten: the icon becomes the rewrite button (a wand), so the
    /// affordance stays at the field's edge instead of a second button covering the selection.
    var rewrite = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(red: 0.18, green: 0.19, blue: 0.21))
            if rewrite {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 12.7, weight: .semibold))
                    .foregroundStyle(.white)
            } else {
                Image("MenuBarCatIcon")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 13.7)
                    .foregroundStyle(.white)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
        .opacity(dimmed ? 0.45 : 1)
        .fixedSize()
    }
}
