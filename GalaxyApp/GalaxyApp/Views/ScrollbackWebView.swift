import AppKit
import WebKit

/// WKWebView wrapper that renders the frozen terminal buffer as HTML.
/// Replaces `ScrollbackTerminalView` for scrollback mode. Handles keyboard
/// navigation via embedded JavaScript and communicates dismiss/ready events
/// back to Swift through `WKScriptMessageHandler`.
///
/// Uses a weak message handler proxy to avoid the retain cycle inherent in
/// `WKUserContentController.add(_:name:)` which retains its handler strongly.
class ScrollbackWebView: NSView {
    let webView: WKWebView

    /// Called when the user presses Escape to dismiss the scrollback overlay.
    var onDismiss: (() -> Void)?

    /// Called once when the HTML page has loaded and is visible.
    var onReady: (() -> Void)?

    /// Line index to scroll to once the HTML page signals "ready".
    private var initialScrollLine: Int

    /// Weak proxy that breaks the WKUserContentController → self retain cycle.
    private let messageProxy: WeakMessageProxy

    /// Short-circuit key view traversal — same fix as GalaxyTerminalView.
    /// Without this, session switching while scrollback is first responder
    /// causes AppKit to walk thousands of SwiftUI-managed views (beach ball).
    override var previousValidKeyView: NSView? { nil }
    override var nextValidKeyView: NSView? { nil }

    init(frame: NSRect, html: String, initialScrollLine: Int, backgroundColor: NSColor = .black) {
        self.initialScrollLine = initialScrollLine
        self.messageProxy = WeakMessageProxy()

        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let userContentController = WKUserContentController()
        config.userContentController = userContentController

        self.webView = WKWebView(
            frame: NSRect(origin: .zero, size: frame.size),
            configuration: config
        )
        super.init(frame: frame)

        // Wire up the weak proxy — breaks the retain cycle
        messageProxy.target = self
        userContentController.add(messageProxy, name: "scrollback")

        // Fill parent bounds
        webView.autoresizingMask = [.width, .height]

        // Transparent WKWebView so it doesn't flash white during HTML load.
        // The parent NSView's layer provides an opaque backing in the theme's
        // background color so the live terminal doesn't bleed through during
        // rubber-band overscroll.
        webView.setValue(false, forKey: "drawsBackground")
        self.wantsLayer = true
        self.layer?.backgroundColor = backgroundColor.cgColor

        // Navigation delegate prevents the galaxy:// baseURL from being
        // opened as an external URL by macOS.
        webView.navigationDelegate = self

        addSubview(webView)

        // Load the rendered HTML
        webView.loadHTMLString(html, baseURL: URL(string: "galaxy://scrollback-terminal-view"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Message Handling (via proxy)

    fileprivate func handleMessage(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String
        else { return }

        switch action {
        case "dismiss":
            onDismiss?()
        case "ready":
            // Page loaded — scroll to initial position, then notify caller
            scrollToLine(initialScrollLine)
            onReady?()
        default:
            break
        }
    }

    // MARK: - JavaScript Interface

    /// Scroll the HTML content to show a specific buffer line at the top.
    func scrollToLine(_ line: Int) {
        webView.evaluateJavaScript(
            "ScrollbackManager.scrollToLine(\(line))"
        )
    }

    /// Inject updated CSS variables for theme/font changes.
    func updateTheme(css: String) {
        let escaped = css
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
        webView.evaluateJavaScript(
            "ScrollbackManager.updateTheme('\(escaped)')"
        )
    }

    /// Reload the entire HTML document (used for full theme rebuilds).
    func reload(html: String, scrollToLine line: Int) {
        initialScrollLine = line
        webView.loadHTMLString(html, baseURL: URL(string: "galaxy://scrollback-terminal-view"))
    }

    // MARK: - First Responder

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        return webView.becomeFirstResponder()
    }

    // MARK: - Teardown

    /// Explicit cleanup — called from TerminalHostView.dismissScrollback()
    /// before the view is removed from the hierarchy. Breaks all references
    /// so ARC can free the WKWebView and its web process.
    func teardown() {
        messageProxy.target = nil
        webView.configuration.userContentController
            .removeAllScriptMessageHandlers()
        webView.stopLoading()
        onDismiss = nil
        onReady = nil
    }

    deinit {
        // Belt-and-suspenders: ensure cleanup even if teardown() wasn't called
        messageProxy.target = nil
        webView.configuration.userContentController
            .removeAllScriptMessageHandlers()
        webView.stopLoading()
    }
}

// MARK: - WKNavigationDelegate

extension ScrollbackWebView: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // Allow the initial HTML load; block any link navigation so the
        // galaxy:// baseURL doesn't trigger macOS URL scheme handling.
        if navigationAction.navigationType == .linkActivated {
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }
}

// MARK: - Weak Message Handler Proxy

/// Weak proxy that implements `WKScriptMessageHandler` and forwards messages
/// to the actual `ScrollbackWebView`. This breaks the retain cycle:
///   WKUserContentController → WeakMessageProxy -(weak)→ ScrollbackWebView
/// Without this, WKUserContentController strongly retains the handler,
/// creating: ScrollbackWebView → WKWebView → config → controller → ScrollbackWebView.
private class WeakMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: ScrollbackWebView?

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        target?.handleMessage(message)
    }
}
