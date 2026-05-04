import Combine
import WebKit

/// Drives Galaxy's find UI against a single WKWebView.
///
/// The view-side `FindBarView` binds to this controller and Swift
/// dispatches operations into the page's `window.GalaxyFind`
/// module via `evaluateJavaScript`. Match counts flow back through
/// the `galaxyFind` message handler so the bar can render
/// "3 of 27" reactively.
///
/// Reverse mode is a fixed property at construction time. The
/// scrollback overlay constructs its controller with
/// `reverse: true` so iteration walks bottom-up; readers use the
/// default forward mode.
@MainActor
final class WebViewFindController: NSObject, ObservableObject {
    @Published var query: String = "" {
        didSet { applyQuery() }
    }
    @Published private(set) var matchCount: Int = 0
    @Published private(set) var matchIndex: Int = -1
    @Published var isVisible: Bool = false {
        didSet {
            if !isVisible { closeFind() }
        }
    }

    /// Reverse iteration: first match = last hit walking up.
    /// Used by the scrollback overlay so Cmd+F results read
    /// most-recent-first.
    let reverse: Bool

    private weak var webView: WKWebView?

    init(webView: WKWebView?, reverse: Bool = false) {
        self.webView = webView
        self.reverse = reverse
        super.init()
        attachMessageHandler()
    }

    /// Re-bind the controller to a different WKWebView (e.g.,
    /// reader swap, SwiftUI lifecycle resets the makeNSView
    /// instance). Re-attaches the message handler on the new
    /// web view's content controller and re-applies the current
    /// query so the new page mirrors the bar's state.
    func bind(to webView: WKWebView?) {
        self.webView = webView
        attachMessageHandler()
        if isVisible { applyQuery() }
    }

    func next() {
        webView?.evaluateJavaScript("GalaxyFind.next()")
    }

    func prev() {
        webView?.evaluateJavaScript("GalaxyFind.prev()")
    }

    private func applyQuery() {
        guard isVisible else { return }
        let escaped = Self.jsEscape(query)
        let opts = reverse ? "{reverse:true}" : "{}"
        webView?.evaluateJavaScript(
            "GalaxyFind.setQuery('\(escaped)', \(opts))"
        )
    }

    private func closeFind() {
        webView?.evaluateJavaScript("GalaxyFind.close()")
        matchCount = 0
        matchIndex = -1
    }

    private func attachMessageHandler() {
        guard let controller = webView?.configuration
            .userContentController else { return }
        controller.removeScriptMessageHandler(forName: "galaxyFind")
        controller.add(
            WeakMessageProxy(target: self),
            name: "galaxyFind"
        )
    }

    fileprivate func handle(_ body: [String: Any]) {
        guard body["event"] as? String == "matches" else { return }
        matchCount = body["count"] as? Int ?? 0
        matchIndex = body["index"] as? Int ?? -1
    }

    private static func jsEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}

/// Weak proxy mirroring the pattern in `ScrollbackWebView` —
/// breaks the `WKUserContentController → handler` retain cycle.
/// `WKUserContentController.add(_:name:)` retains its handler
/// strongly; the message handler weakly retains the controller
/// so ARC can free the controller (and its WKWebView reference)
/// when the SwiftUI parent goes away.
private final class WeakMessageProxy:
    NSObject, WKScriptMessageHandler
{
    weak var target: WebViewFindController?

    init(target: WebViewFindController) {
        self.target = target
    }

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any] else {
            return
        }
        Task { @MainActor in
            self.target?.handle(body)
        }
    }
}
