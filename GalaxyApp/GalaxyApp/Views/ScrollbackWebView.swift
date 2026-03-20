import AppKit
import WebKit

// MARK: - ScrollbackNote

/// Ephemeral note attached to a range of lines in the scrollback buffer.
/// Exists only while the scrollback overlay is active — no persistence.
struct ScrollbackNote: Identifiable {
    let id: UUID
    let startLine: Int       // 0-based line index in buffer
    let endLine: Int         // inclusive
    let lineContent: String  // full text of lines startLine...endLine
    var content: String      // the note text
    let createdAt: Date
}

// MARK: - ScrollbackWebView

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

    /// Called when JS requests dismiss confirmation (notes exist).
    var onConfirmDismiss: (() -> Void)?

    /// Called when JS sends the formatted note message to Claude.
    var onSendToClaude: ((String) -> Void)?

    /// Called when JS requests confirmation to discard new note form content.
    var onConfirmDiscardForm: (() -> Void)?

    /// Called when JS requests confirmation to discard edit changes.
    var onConfirmDiscardEdit: (() -> Void)?

    /// In-memory note storage. Cleared on teardown.
    private(set) var notes: [ScrollbackNote] = []

    /// True when there's at least one note.
    var hasNotes: Bool { !notes.isEmpty }

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

        // Navigation delegate prevents link-activated navigations from
        // triggering macOS URL scheme handling.
        webView.navigationDelegate = self

        addSubview(webView)

        // Load the rendered HTML with bundle resource base URL so emoji
        // JS files can be loaded via <script src="..."> tags.
        let baseURL = Bundle.main.resourceURL
        webView.loadHTMLString(html, baseURL: baseURL)
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
        case "confirmDismiss":
            onConfirmDismiss?()
        case "createNote":
            handleCreateNote(body)
        case "updateNote":
            handleUpdateNote(body)
        case "deleteNote":
            handleDeleteNote(body)
        case "sendToClaude":
            guard let msg = body["message"] as? String else { return }
            onSendToClaude?(msg)
        case "confirmDiscardForm":
            onConfirmDiscardForm?()
        case "confirmDiscardEdit":
            onConfirmDiscardEdit?()
        default:
            break
        }
    }

    // MARK: - Note Handlers

    private func handleCreateNote(_ body: [String: Any]) {
        guard let startLine = body["startLine"] as? Int,
              let endLine = body["endLine"] as? Int,
              let lineContent = body["lineContent"] as? String,
              let content = body["content"] as? String
        else { return }

        let note = ScrollbackNote(
            id: UUID(),
            startLine: startLine,
            endLine: endLine,
            lineContent: lineContent,
            content: content,
            createdAt: Date()
        )
        notes.append(note)

        // Respond to JS with the created note (including server-assigned ID)
        let json = noteToJSON(note)
        webView.evaluateJavaScript(
            "ScrollbackManager.notes.noteCreated(\(json))"
        )
    }

    private func handleUpdateNote(_ body: [String: Any]) {
        guard let idStr = body["id"] as? String,
              let id = UUID(uuidString: idStr),
              let content = body["content"] as? String
        else { return }

        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[idx].content = content

        let json = noteToJSON(notes[idx])
        webView.evaluateJavaScript(
            "ScrollbackManager.notes.noteUpdated(\(json))"
        )
    }

    private func handleDeleteNote(_ body: [String: Any]) {
        guard let idStr = body["id"] as? String,
              let id = UUID(uuidString: idStr)
        else { return }

        notes.removeAll { $0.id == id }
        webView.evaluateJavaScript(
            "ScrollbackManager.notes.noteDeleted('\(idStr)')"
        )
    }

    private func noteToJSON(_ note: ScrollbackNote) -> String {
        let escapedContent = note.content
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        let escapedLineContent = note.lineContent
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return """
        {"id":"\(note.id.uuidString)","startLine":\(note.startLine),\
        "endLine":\(note.endLine),"lineContent":"\(escapedLineContent)",\
        "content":"\(escapedContent)","number":\(notes.count)}
        """
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
    /// Preserves note state across the reload by round-tripping through Swift.
    func reload(html: String, scrollToLine line: Int) {
        initialScrollLine = line
        let baseURL = Bundle.main.resourceURL
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    /// After a reload, restore note cards and form state into the new HTML.
    /// Called from the onReady callback after the page signals readiness.
    func restoreNoteState() {
        guard !notes.isEmpty else { return }
        // Re-insert all note cards
        for note in notes {
            let json = noteToJSON(note)
            webView.evaluateJavaScript(
                "ScrollbackManager.notes.noteCreated(\(json))"
            )
        }
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
        notes.removeAll()
        onDismiss = nil
        onReady = nil
        onConfirmDismiss = nil
        onSendToClaude = nil
        onConfirmDiscardForm = nil
        onConfirmDiscardEdit = nil
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
