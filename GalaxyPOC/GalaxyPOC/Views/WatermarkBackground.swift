import SwiftUI

/// Subtle galaxy icon watermark for empty state backgrounds.
/// Preserves image detail with grayscale desaturation.
struct WatermarkBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    /// Opacity varies by theme
    private var watermarkOpacity: Double {
        colorScheme == .dark ? 0.08 : 0.12
    }

    var body: some View {
        Image("GalaxyWatermark")
            .resizable()
            .saturation(0)  // Desaturate to grayscale
            .colorInvert(colorScheme == .light)  // Invert for light mode
            .opacity(watermarkOpacity)
            .aspectRatio(contentMode: .fit)
            .scaleEffect(1.75)  // Scale up from center
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension View {
    /// Conditionally apply color invert
    @ViewBuilder
    func colorInvert(_ active: Bool) -> some View {
        if active {
            self.colorInvert()
        } else {
            self
        }
    }
}
