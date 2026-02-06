import SwiftUI

/// Subtle galaxy icon watermark for empty state backgrounds.
/// Preserves image detail with grayscale desaturation.
struct WatermarkBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    /// Opacity varies by theme
    private var watermarkOpacity: Double {
        colorScheme == .dark ? 0.08 : 0.06
    }

    var body: some View {
        Image("GalaxyWatermark")
            .resizable()
            .saturation(0)  // Desaturate to grayscale
            .opacity(watermarkOpacity)
            .aspectRatio(contentMode: .fit)
            .scaleEffect(1.75)  // Scale up from center
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
