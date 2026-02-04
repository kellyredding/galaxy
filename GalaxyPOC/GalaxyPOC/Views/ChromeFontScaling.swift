import SwiftUI

// MARK: - Environment Key for Chrome Font Size

private struct ChromeFontSizeKey: EnvironmentKey {
    static let defaultValue: CGFloat = 13.0
}

extension EnvironmentValues {
    var chromeFontSize: CGFloat {
        get { self[ChromeFontSizeKey.self] }
        set { self[ChromeFontSizeKey.self] = newValue }
    }
}

// MARK: - Chrome Font Size Calculator

/// Helper for computing scaled font sizes from a base chrome size.
/// Use with @Environment(\.chromeFontSize) for reactive updates.
struct ChromeFontSize {
    let base: CGFloat

    init(_ base: CGFloat) {
        self.base = base
    }

    /// Scale factor relative to default base (13pt)
    private var scaleFactor: CGFloat { base / 13.0 }

    // MARK: - Scaled Sizes

    /// Tiny caption (for badges, indicators)
    var tiny: CGFloat { 9 * scaleFactor }

    /// Small caption text
    var caption: CGFloat { 10 * scaleFactor }

    /// Caption 2 (slightly larger caption)
    var caption2: CGFloat { 11 * scaleFactor }

    /// Body text (base size)
    var body: CGFloat { base }

    /// Subheadline
    var subheadline: CGFloat { 12 * scaleFactor }

    /// Headline
    var headline: CGFloat { 14 * scaleFactor }

    /// Title 3
    var title3: CGFloat { 16 * scaleFactor }

    /// Title 2
    var title2: CGFloat { 18 * scaleFactor }

    /// Large title
    var largeTitle: CGFloat { 24 * scaleFactor }

    /// Icon sizes
    var iconSmall: CGFloat { 12 * scaleFactor }
    var iconMedium: CGFloat { 18 * scaleFactor }
    var iconLarge: CGFloat { 48 * scaleFactor }
    var iconXLarge: CGFloat { 64 * scaleFactor }
}

// MARK: - View Extension for Chrome Fonts

extension View {
    /// Apply a chrome-scaled system font
    func chromeFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        self.font(.system(size: size, weight: weight, design: design))
    }

    /// Apply a chrome-scaled monospaced font
    func chromeFontMono(size: CGFloat, weight: Font.Weight = .regular) -> some View {
        self.font(.system(size: size, weight: weight, design: .monospaced))
    }
}
