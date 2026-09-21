import Combine
import Foundation

/// Leading space the window's traffic lights occupy, for the control
/// strip to reserve. Zero in full screen, where AppKit takes the
/// buttons out of the window entirely.
final class WindowChromeMetrics: ObservableObject {
    static let shared = WindowChromeMetrics()

    /// Stands in until the buttons can be measured, and whenever they
    /// cannot be. Wide enough to clear the stock three-button layout.
    static let fallbackInset: CGFloat = 78

    /// Gap between the zoom button and the first control in the strip.
    static let buttonGap: CGFloat = 8

    @Published private(set) var trafficLightInset: CGFloat
        = WindowChromeMetrics.fallbackInset

    private var measuredInset: CGFloat = WindowChromeMetrics.fallbackInset
    private var isFullScreen = false

    private init() {}

    func setMeasuredInset(_ inset: CGFloat) {
        measuredInset = inset
        publish()
    }

    func setFullScreen(_ full: Bool) {
        isFullScreen = full
        publish()
    }

    private func publish() {
        let next = isFullScreen ? 0 : measuredInset
        guard next != trafficLightInset else { return }
        trafficLightInset = next
    }
}
