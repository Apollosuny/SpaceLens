import SwiftUI

/// Liquid Glass on macOS 26 and later, with material and bordered-button fallbacks on macOS 15.
/// Glass belongs to the floating control layer (tooltips, buttons over content), never to content itself.
extension View {
    /// A glass (or material) background clipped to `shape`.
    @ViewBuilder
    func glassSurface(in shape: some Shape = .rect(cornerRadius: 11), interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.stroke(.separator, lineWidth: 0.5))
        }
    }

    /// The prominent (accent-filled) action button.
    @ViewBuilder
    func prominentGlassButtonStyle() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    /// A secondary action button.
    @ViewBuilder
    func glassButtonStyle() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }
}
