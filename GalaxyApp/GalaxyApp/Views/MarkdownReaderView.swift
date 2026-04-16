import SwiftUI
import WebKit
import Markdown

// AnnotationMessage enum is in AnnotationSupport.swift

// MARK: - Silent WKWebView

/// WKWebView subclass that silently consumes function key events
/// (F1–F20) to prevent NSBeep from firing when the responder chain
/// can't handle them. This allows dictation triggers like Fn+F11
/// to work without system beep noise — dictation itself operates
/// through NSTextInputClient, not keyDown events.
class SilentFunctionKeyWebView: WKWebView {
    /// Short-circuit key view traversal — same fix as GalaxyTerminalView
    /// and InlineEditField. When makeFirstResponder targets this WKWebView
    /// (e.g. restoreWebViewFocus on session/tab switch), AppKit walks the
    /// key view chain across the full ZStack view tree.
    override var previousValidKeyView: NSView? { nil }
    override var nextValidKeyView: NSView? { nil }

    /// Current zoom level (1.0 = 100%)
    private var zoomLevel: CGFloat = 1.0

    override init(
        frame: CGRect,
        configuration: WKWebViewConfiguration
    ) {
        super.init(
            frame: frame,
            configuration: configuration
        )
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func performKeyEquivalent(
        with event: NSEvent
    ) -> Bool {
        // F1 (0xF704) through F20 (0xF717) —
        // consume silently
        if event.modifierFlags.contains(.function),
           event.charactersIgnoringModifiers?
               .unicodeScalars.first
               .map({
                   $0.value >= 0xF704
                       && $0.value <= 0xF717
               }) == true
        {
            return true
        }

        // Cmd+= or Cmd++: zoom in
        if event.modifierFlags.contains(.command),
           let chars = event
               .charactersIgnoringModifiers,
           chars == "=" || chars == "+"
        {
            adjustZoom(by: 0.1)
            return true
        }

        // Cmd+-: zoom out
        if event.modifierFlags.contains(.command),
           let chars = event
               .charactersIgnoringModifiers,
           chars == "-"
        {
            adjustZoom(by: -0.1)
            return true
        }

        // Cmd+0: reset zoom
        if event.modifierFlags.contains(.command),
           let chars = event
               .charactersIgnoringModifiers,
           chars == "0"
        {
            resetZoom()
            return true
        }

        // Cmd+S: pass through to menu system for
        // scrollback entry. WKWebView's default
        // performKeyEquivalent may consume this
        // before the menu sees it.
        if event.modifierFlags.contains(.command),
           let chars = event
               .charactersIgnoringModifiers,
           chars == "s"
        {
            return false
        }

        return super.performKeyEquivalent(
            with: event
        )
    }

    private func adjustZoom(by delta: CGFloat) {
        zoomLevel = min(
            3.0, max(0.5, zoomLevel + delta)
        )
        applyZoom()
    }

    private func resetZoom() {
        zoomLevel = 1.0
        applyZoom()
    }

    private func applyZoom() {
        evaluateJavaScript("""
            document.body.style.transform
                = 'scale(\(zoomLevel))';
            document.body.style.transformOrigin
                = 'top left';
            document.body.style.width
                = '\(100.0 / zoomLevel)%';
        """)
    }

    // MARK: - File Drag and Drop

    override func draggingEntered(
        _ sender: NSDraggingInfo
    ) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) else { return [] }

        evaluateJavaScript(
            "document.body.classList"
            + ".add('file-drop-active')"
        )
        return .copy
    }

    override func draggingUpdated(
        _ sender: NSDraggingInfo
    ) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) else { return [] }
        return .copy
    }

    override func draggingExited(
        _ sender: NSDraggingInfo?
    ) {
        evaluateJavaScript(
            "document.body.classList"
            + ".remove('file-drop-active')"
        )
    }

    override func draggingEnded(
        _ sender: NSDraggingInfo
    ) {
        evaluateJavaScript(
            "document.body.classList"
            + ".remove('file-drop-active')"
        )
    }

    override func performDragOperation(
        _ sender: NSDraggingInfo
    ) -> Bool {
        defer {
            evaluateJavaScript(
                "document.body.classList"
                + ".remove('file-drop-active')"
            )
        }

        guard let urls = sender.draggingPasteboard
            .readObjects(
                forClasses: [NSURL.self],
                options: [
                    .urlReadingFileURLsOnly: true,
                ]
            ) as? [URL], !urls.isEmpty
        else { return false }

        // Deduplicate by path
        var seen = Set<String>()
        var paths: [String] = []
        for url in urls {
            let p = url.standardized.path
            if !seen.contains(p) {
                seen.insert(p)
                paths.append(p)
            }
        }

        // Escape for JS string literal
        let jsArray = paths.map { path in
            let escaped = path
                .replacingOccurrences(
                    of: "\\", with: "\\\\"
                )
                .replacingOccurrences(
                    of: "'", with: "\\'"
                )
            return "'\(escaped)'"
        }.joined(separator: ",")

        evaluateJavaScript(
            "if (typeof handleFileDrop"
            + " !== 'undefined')"
            + " { handleFileDrop([\(jsArray)]); }"
        )
        return true
    }
}

// MARK: - MarkdownReaderView

/// Renders markdown content in a themed WKWebView with source-line
/// anchored blocks and inline annotation support.
///
/// The Coordinator acts as both WKScriptMessageHandler (receiving JS
/// messages) and WKNavigationDelegate (injecting annotations after
/// page load). The webViewRef binding exposes the WKWebView so the
/// parent view can call evaluateJavaScript for annotation actions.
struct MarkdownReaderView: NSViewRepresentable {
    let markdown: String
    let isDark: Bool
    let annotations: [SnapshotAnnotation]
    let annotationHTMLMap: [Int32: String]
    @Binding var webViewRef: WKWebView?
    var onAnnotationMessage: ((AnnotationMessage) -> Void)?
    var annotationsEnabled: Bool = true
    /// Display label for annotation form headers
    /// (e.g. "Snapshot #3", "Artifact #19").
    let itemLabel: String
    /// Base URL name for internal routing
    /// (e.g. "snapshot-reader", "artifact-reader").
    var baseUrlName: String = "reader"

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "annotation")
        let webView = SilentFunctionKeyWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.isInspectable = true
        webView.navigationDelegate = context.coordinator

        // Defer binding update to avoid mutating state during view update
        DispatchQueue.main.async { self.webViewRef = webView }

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Keep callback current (closure may capture new state)
        context.coordinator.onAnnotationMessage = onAnnotationMessage

        let html = renderMarkdownToHTML(markdown, isDark: isDark)
        let htmlHash = html.hashValue
        guard context.coordinator.lastHTMLHash != htmlHash else { return }

        context.coordinator.lastHTMLHash = htmlHash
        context.coordinator.annotationsEnabled =
            self.annotationsEnabled
        context.coordinator.pendingAnnotations = self.annotations
        context.coordinator.pendingAnnotationHTMLMap = self.annotationHTMLMap
        context.coordinator.pendingItemLabel = self.itemLabel

        let baseURL = URL(
            string: "galaxy://\(self.baseUrlName)"
        )

        // When annotations are disabled, skip form-state
        // save and load HTML directly.
        guard annotationsEnabled else {
            webView.loadHTMLString(html, baseURL: baseURL)
            return
        }

        // Save form state before reload (no-op on first load when
        // AnnotationManager doesn't exist yet). Load inside the
        // callback so form state is captured before the page reloads.
        webView.evaluateJavaScript(
            """
            typeof AnnotationManager !== 'undefined' && AnnotationManager.blocks.length > 0
                ? JSON.stringify(AnnotationManager.getFormState())
                : null
            """
        ) { result, _ in
            if let json = result as? String {
                context.coordinator.savedFormState = json
            }
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.stopLoading()
        nsView.configuration.userContentController
            .removeScriptMessageHandler(forName: "annotation")
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: - Coordinator

    class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var lastHTMLHash: Int = 0
        var onAnnotationMessage: ((AnnotationMessage) -> Void)?
        var annotationsEnabled: Bool = true

        /// Annotation data queued for injection after page load.
        var pendingAnnotations: [SnapshotAnnotation]?
        var pendingAnnotationHTMLMap: [Int32: String]?
        var pendingItemLabel: String?

        /// Form state saved before a theme-change reload.
        var savedFormState: String?

        // MARK: WKScriptMessageHandler

        func userContentController(
            _ controller: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "annotation",
                  let body = message.body as? [String: Any],
                  let action = body["action"] as? String else { return }

            switch action {
            case "create":
                guard let startLine = body["startLine"] as? Int,
                      let endLine = body["endLine"] as? Int,
                      let content = body["content"] as? String else { return }
                onAnnotationMessage?(.create(
                    startLine: Int32(startLine),
                    endLine: Int32(endLine),
                    content: content
                ))
            case "update":
                guard let number = body["number"] as? Int,
                      let content = body["content"] as? String else { return }
                onAnnotationMessage?(.update(
                    number: Int32(number),
                    content: content
                ))
            case "delete":
                guard let number = body["number"] as? Int else { return }
                onAnnotationMessage?(.delete(number: Int32(number)))
            case "confirmDragReplace":
                guard let startIdx = body["startIdx"] as? Int,
                      let endIdx = body["endIdx"] as? Int
                else { return }
                onAnnotationMessage?(
                    .confirmDragReplace(
                        startIdx: startIdx,
                        endIdx: endIdx
                    )
                )
            default:
                break
            }
        }

        // MARK: WKNavigationDelegate

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url,
               url.scheme == "http" || url.scheme == "https" {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Skip annotation injection when disabled
            guard annotationsEnabled else {
                pendingAnnotations = nil
                pendingAnnotationHTMLMap = nil
                pendingItemLabel = nil
                return
            }

            // Inject annotation data after page load
            if let annotations = pendingAnnotations,
               let htmlMap = pendingAnnotationHTMLMap,
               let label = pendingItemLabel {

                let annotationDicts: [[String: Any]]
                    = annotations.map { a in
                    var dict: [String: Any] = [
                        "id": a.id,
                        "number": a.number,
                        "start_line": a.startLine,
                        "end_line": a.endLine,
                        "content": a.content,
                        "created_at": a.createdAt,
                        "updated_at": a.updatedAt,
                    ]
                    if let rn = a.reviewNumber {
                        dict["review_number"] = rn
                    }
                    if let rra = a.reviewReviewedAt {
                        dict["review_reviewed_at"]
                            = rra
                    }
                    return dict
                }
                let htmlMapDict: [String: String]
                    = Dictionary(
                        uniqueKeysWithValues:
                            htmlMap.map {
                                (String($0.key), $0.value)
                            }
                    )
                let payload: [String: Any] = [
                    "itemLabel": label,
                    "annotations": annotationDicts,
                    "htmlMap": htmlMapDict,
                ]

                if let jsonData
                    = try? JSONSerialization.data(
                        withJSONObject: payload
                    ),
                   let jsonString = String(
                       data: jsonData,
                       encoding: .utf8
                   )
                {
                    webView.evaluateJavaScript(
                        "AnnotationManager.initialize("
                        + "\(jsonString))"
                    )
                }

                pendingAnnotations = nil
                pendingAnnotationHTMLMap = nil
                pendingItemLabel = nil
            }

            // Restore form state after theme-change reload
            if let formState = savedFormState {
                webView.evaluateJavaScript("AnnotationManager.restoreFormState(\(formState))")
                savedFormState = nil
            }
        }
    }
}

// MARK: - Rendering Pipeline

/// Parse markdown with swift-markdown and emit line-anchored HTML.
func renderMarkdownToHTML(_ source: String, isDark: Bool) -> String {
    let document = Document(parsing: source)
    var visitor = LineAnchoredHTMLVisitor()
    let bodyHTML = visitor.visit(document)

    // Load vendored highlight.js and theme CSS from bundle
    let hjsURL = Bundle.main.url(forResource: "highlight.min",
                                  withExtension: "js")
    let hjsContent = hjsURL.flatMap { try? String(contentsOf: $0) } ?? ""

    let themeName = isDark ? "github-dark.min" : "github.min"
    let themeURL = Bundle.main.url(forResource: themeName,
                                    withExtension: "css")
    let themeCSS = themeURL.flatMap { try? String(contentsOf: $0) } ?? ""

    return buildFullHTML(
        bodyHTML: bodyHTML,
        highlightJS: hjsContent,
        highlightCSS: themeCSS,
        isDark: isDark
    )
}

// emojiDataJS and emojiAutocompleteJS are in
// AnnotationSupport.swift

private let mermaidJS: String = {
    guard let url = Bundle.main.url(
        forResource: "mermaid.min",
        withExtension: "js"
    ),
        let content = try? String(
            contentsOf: url, encoding: .utf8
        )
    else { return "" }
    return content
}()

/// Build a complete HTML document with embedded styles, highlight.js,
/// and the AnnotationManager JavaScript module.
private func buildFullHTML(
    bodyHTML: String,
    highlightJS: String,
    highlightCSS: String,
    isDark: Bool
) -> String {
    let themeClass = isDark ? "dark" : "light"

    return """
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Galaxy Snapshot Reader</title>
    <style>
    :root {
        color-scheme: light dark;
    }
    body.dark {
        --bg: #1e1e1e;
        --fg: #e0e0e0;
        --code-bg: #2d2d2d;
        --code-border: #444;
        --blockquote-border: #555;
        --blockquote-fg: #aaa;
        --table-border: #444;
        --table-header-bg: #333;
        --link-color: #58a6ff;
        --hr-color: #444;
        --annotation-active-bg: rgba(255, 255, 120, 0.12);
        --annotation-active-border: rgba(255, 220, 50, 0.5);
        --annotation-active-block-bg: rgba(255, 255, 120, 0.08);
        --annotation-active-block-border: rgba(255, 220, 50, 0.35);
        --delete-color: #ff5252;
    }
    body.light {
        --bg: #ffffff;
        --fg: #333333;
        --code-bg: #f5f5f5;
        --code-border: #ddd;
        --blockquote-border: #ddd;
        --blockquote-fg: #666;
        --table-border: #ddd;
        --table-header-bg: #f0f0f0;
        --link-color: #0969da;
        --hr-color: #d0d7de;
        --annotation-active-bg: rgba(255, 248, 220, 0.8);
        --annotation-active-border: #d4a017;
        --annotation-active-block-bg: rgba(255, 248, 220, 0.5);
        --annotation-active-block-border: rgba(212, 160, 23, 0.6);
        --delete-color: #ff3b30;
    }
    body {
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI",
                     Helvetica, Arial, sans-serif;
        font-size: 14px;
        line-height: 1.6;
        color: var(--fg);
        background: var(--bg);
        padding: 16px 24px;
        margin: 0;
        -webkit-font-smoothing: antialiased;
    }
    h1, h2, h3, h4, h5, h6 {
        margin-top: 24px;
        margin-bottom: 16px;
        font-weight: 600;
        line-height: 1.25;
    }
    h1 { font-size: 2em; padding-bottom: 0.3em; border-bottom: 1px solid var(--hr-color); }
    h2 { font-size: 1.5em; padding-bottom: 0.3em; border-bottom: 1px solid var(--hr-color); }
    h3 { font-size: 1.25em; }
    h4 { font-size: 1em; }
    h5 { font-size: 0.875em; }
    h6 { font-size: 0.85em; color: var(--blockquote-fg); }
    p { margin-top: 0; margin-bottom: 16px; }
    a { color: var(--link-color); text-decoration: none; }
    a:hover { text-decoration: underline; }
    code {
        font-family: "SF Mono", "Menlo", "Monaco", "Courier New", monospace;
        font-size: 85%;
        background: var(--code-bg);
        border-radius: 6px;
        padding: 0.2em 0.4em;
    }
    pre {
        background: var(--code-bg);
        border: 1px solid var(--code-border);
        border-radius: 6px;
        padding: 16px;
        overflow-x: auto;
        margin-top: 0;
        margin-bottom: 16px;
        line-height: 1.45;
    }
    pre code {
        background: none;
        padding: 0;
        font-size: 85%;
        border-radius: 0;
    }

    /* Code block line-level annotation support */
    .code-line {
        margin: 0;
        padding: 0;
        line-height: 1.45;
    }
    .code-line code,
    .code-line code.hljs {
        display: inline;
        background: none;
        padding: 0;
        border-radius: 0;
        font-size: 85%;
        white-space: pre;
    }
    .code-line.annotation-highlight {
        background-color: rgba(88, 166, 255, 0.12);
        border-left: 3px solid
            rgba(88, 166, 255, 0.6);
        padding-left: 8px;
        margin-left: -11px;
    }
    .code-line.annotation-expanded-highlight {
        background-color: rgba(210, 153, 34, 0.10);
        border-left: 3px solid
            rgba(210, 153, 34, 0.6);
        padding-left: 8px;
        margin-left: -11px;
    }

    /* Table row annotation support */
    tr.md-block.annotation-highlight td,
    tr.md-block.annotation-highlight th {
        background-color: rgba(88, 166, 255, 0.12);
    }
    tr.md-block.annotation-highlight td:first-child,
    tr.md-block.annotation-highlight th:first-child {
        border-left: 3px solid
            rgba(88, 166, 255, 0.6);
    }
    tr.md-block.annotation-expanded-highlight td,
    tr.md-block.annotation-expanded-highlight th {
        background-color: rgba(210, 153, 34, 0.10);
    }
    tr.md-block.annotation-expanded-highlight
        td:first-child,
    tr.md-block.annotation-expanded-highlight
        th:first-child {
        border-left: 3px solid
            rgba(210, 153, 34, 0.6);
    }

    .mermaid {
        text-align: center;
        margin-bottom: 16px;
        overflow-x: auto;
    }
    .mermaid svg {
        max-width: 100%;
        height: auto;
    }
    blockquote {
        margin: 0 0 16px 0;
        padding: 0 1em;
        color: var(--blockquote-fg);
        border-left: 0.25em solid var(--blockquote-border);
    }
    ul, ol { margin-top: 0; margin-bottom: 16px; padding-left: 2em; }
    li + li { margin-top: 0.25em; }
    table {
        border-spacing: 0;
        border-collapse: collapse;
        margin-top: 0;
        margin-bottom: 16px;
        width: auto;
    }
    th, td {
        padding: 6px 13px;
        border: 1px solid var(--table-border);
    }
    th {
        font-weight: 600;
        background: var(--table-header-bg);
    }
    hr {
        height: 0.25em;
        padding: 0;
        margin: 24px 0;
        background-color: var(--hr-color);
        border: 0;
        border-radius: 2px;
    }
    img { max-width: 100%; }
    .md-block { /* Line-anchored block wrapper — no visual styling */ }

    /* --- Annotation styles --- */

    .annotation-highlight {
        background-color: rgba(88, 166, 255, 0.12);
        border-left: 3px solid rgba(88, 166, 255, 0.6);
        padding-left: 8px;
        margin-left: -11px;
        transition: background-color 0.15s ease;
    }
    .annotation-form {
        position: absolute;
        left: 24px;
        right: 24px;
        z-index: 10;
        padding: 8px 12px;
        border: 1px solid rgba(88, 166, 255, 0.4);
        border-radius: 6px;
        background: var(--code-bg);
        box-sizing: border-box;
    }
    .annotation-form-header {
        font-size: 11px;
        color: var(--blockquote-fg);
        margin-bottom: 4px;
        font-family: "SF Mono", monospace;
    }
    .annotation-textarea {
        width: 100%;
        min-height: 1.6em;
        padding: 6px 8px;
        border: 1px solid var(--code-border);
        border-radius: 4px;
        background: var(--bg);
        color: var(--fg);
        font-family: -apple-system, sans-serif;
        font-size: 13px;
        line-height: 1.5;
        resize: none;
        overflow: hidden;
        box-sizing: border-box;
    }
    .annotation-textarea:focus {
        outline: none;
        border-color: rgba(88, 166, 255, 0.6);
    }
    .annotation-textarea::placeholder {
        color: var(--blockquote-fg);
        opacity: 0.6;
    }
    .annotation-card {
        position: absolute;
        left: 24px;
        right: 24px;
        z-index: 10;
        padding: 6px 10px;
        border: 1px solid var(--code-border);
        border-radius: 6px;
        background: var(--code-bg);
        font-size: 13px;
        box-sizing: border-box;
    }
    .annotation-card-header {
        display: flex;
        align-items: center;
        gap: 6px;
        font-size: 11px;
        color: var(--blockquote-fg);
        margin-bottom: 2px;
    }
    .annotation-card-ref {
        font-family: "SF Mono", monospace;
    }
    .annotation-card-meta {
        font-family: "SF Mono", monospace;
        opacity: 0.5;
    }
    .annotation-card-actions {
        margin-left: auto;
        display: flex;
        gap: 6px;
        opacity: 0;
        transition: opacity 0.15s;
    }
    .annotation-card:hover .annotation-card-actions {
        opacity: 1;
    }
    .annotation-card-actions button {
        background: none;
        border: none;
        color: var(--blockquote-fg);
        cursor: pointer;
        font-size: 15px;
        padding: 3px 6px;
        border-radius: 4px;
        line-height: 1;
    }
    .annotation-card-actions button:hover {
        background: var(--table-header-bg);
        color: var(--fg);
    }
    .annotation-card-actions .annotation-btn-delete {
        color: var(--delete-color);
    }
    .annotation-card-actions .annotation-btn-delete:hover {
        background: rgba(255, 59, 48, 0.1);
        color: var(--delete-color);
    }
    .annotation-card-actions:has(.confirming) {
        opacity: 1;
    }
    .annotation-card-actions:has(.confirming) .annotation-btn-edit {
        display: none;
    }
    .annotation-card:has(.annotation-edit-textarea) .annotation-card-actions {
        display: none;
    }
    .annotation-btn-delete.confirming {
        background: rgba(220, 40, 30, 0.75) !important;
        color: #fff !important;
        font-size: 12px;
        font-weight: 600;
        font-family: -apple-system, sans-serif;
        padding: 4px 12px !important;
        position: relative;
        overflow: hidden;
    }
    .annotation-btn-delete.confirming:hover {
        background: rgba(220, 40, 30, 0.85) !important;
        color: #fff !important;
    }
    .annotation-btn-delete.confirming::after {
        content: '';
        position: absolute;
        bottom: 0;
        left: 0;
        height: 1.5px;
        background: rgba(255, 255, 255, 0.8);
        animation: confirmDrain 5s linear forwards;
    }
    @keyframes confirmDrain {
        from { width: 100%; }
        to { width: 0%; }
    }
    .annotation-card-content {
        line-height: 1.5;
        color: var(--fg);
    }
    .annotation-card-content.collapsed {
        max-height: 1.6em;
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
    }
    .annotation-card-content.collapsed p {
        display: inline;
        margin: 0;
    }
    .annotation-edit-textarea {
        width: 100%;
        min-height: 1.6em;
        padding: 4px 6px;
        border: 1px solid rgba(88, 166, 255, 0.4);
        border-radius: 4px;
        background: var(--bg);
        color: var(--fg);
        font-family: -apple-system, sans-serif;
        font-size: 13px;
        line-height: 1.5;
        resize: none;
        overflow: hidden;
        box-sizing: border-box;
    }
    .annotation-card.expanded {
        border-color: var(--annotation-active-border);
        background: var(--annotation-active-bg);
    }
    .annotation-expanded-highlight {
        background-color: var(--annotation-active-block-bg);
        border-left: 3px solid var(--annotation-active-block-border);
        padding-left: 8px;
        margin-left: -11px;
        transition: background-color 0.15s ease;
    }
    .annotation-expand-hint {
        display: block;
        font-size: 11px;
        color: var(--blockquote-fg);
        opacity: 0.5;
        margin-top: 2px;
        cursor: pointer;
    }
    .annotation-card.expanded .annotation-expand-hint {
        display: none;
    }
    .annotation-spacer {
        pointer-events: none;
        line-height: 0;
        font-size: 0;
    }
    .annotation-spacer.form-spacer {
        margin: 8px 0;
    }
    .annotation-spacer.card-spacer {
        margin: 6px 0;
    }
    .annotation-spacer-row td {
        padding: 0 !important;
        border: none !important;
        background: transparent !important;
        line-height: 0;
    }
    /* --- Emoji autocomplete --- */
    .emoji-popup {
        position: absolute;
        z-index: 100;
        min-width: 200px;
        max-width: 300px;
        max-height: 280px;
        overflow-y: auto;
        border: 1px solid var(--code-border);
        border-radius: 6px;
        background: var(--code-bg);
        box-shadow: 0 4px 12px rgba(0, 0, 0, 0.15);
        font-family: -apple-system, sans-serif;
        font-size: 13px;
        padding: 4px 0;
        display: none;
    }
    .emoji-popup-row {
        display: flex;
        align-items: center;
        padding: 4px 10px;
        cursor: pointer;
        gap: 8px;
    }
    .emoji-popup-row.selected,
    .emoji-popup-row.selected:hover {
        background: rgba(88, 166, 255, 0.2);
    }
    .emoji-popup-row:hover {
        background: rgba(88, 166, 255, 0.12);
    }
    .emoji-popup-emoji {
        font-size: 18px;
        width: 24px;
        text-align: center;
        flex-shrink: 0;
    }
    .emoji-popup-name {
        color: var(--fg);
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
    }
    .emoji-popup-name .emoji-match {
        font-weight: 600;
    }
    </style>
    <style>\(highlightCSS)</style>
    </head>
    <body class="\(themeClass)">
    \(bodyHTML)
    <script>\(highlightJS)</script>
    <script>if(typeof hljs !== 'undefined') hljs.highlightAll();</script>
    <script>
    function autoGrow(el) {
        el.style.height = 'auto';
        el.style.height = el.scrollHeight + 'px';
        if (typeof AnnotationManager !== 'undefined' && AnnotationManager.syncAllPositions) {
            AnnotationManager.syncAllPositions();
        }
    }

    const AnnotationManager = {
        // --- State ---
        blocks: [],
        currentBlockIndex: 0,
        highlightStart: 0,
        highlightEnd: 0,
        annotations: [],
        annotationHTMLMap: {},
        formElement: null,
        formSpacer: null,
        formSpacerRow: null,
        cardSpacers: {},
        resizeObserver: null,
        editingNumber: null,
        expandedNumber: null,
        confirmingDeleteNumber: null,
        confirmDeleteTimer: null,
        confirmArmedAt: null,
        submitting: false,
        deleting: false,
        itemLabel: '',
        editIconSVG: '<svg width="1em" height="1em" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M17 3a2.828 2.828 0 114 4L7.5 20.5 2 22l1.5-5.5L17 3z"/></svg>',
        deleteIconSVG: '<svg width="1em" height="1em" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M3 6h18"/><path d="M8 6V4h8v2"/><path d="M5 6v14a1 1 0 001 1h12a1 1 0 001-1V6"/><path d="M10 11v6"/><path d="M14 11v6"/></svg>',

        // --- Initialization ---

        initialize(data) {
            this.itemLabel = data.itemLabel || '';
            this.annotations = data.annotations || [];
            this.annotationHTMLMap = data.htmlMap || {};

            // Enumerate leaf-level blocks (no md-block children)
            var allBlocks = document.querySelectorAll('.md-block');
            this.blocks = Array.from(allBlocks).filter(
                function(el) { return !el.querySelector('.md-block'); }
            );

            if (this.blocks.length === 0) return;

            this.currentBlockIndex = -1;
            this.highlightStart = -1;
            this.highlightEnd = -1;

            this.createForm();
            this.renderAllAnnotations();

            // Drag-select detection on md-blocks
            var self = this;
            document.addEventListener('mouseup', function(e) {
                // Ignore clicks on annotation UI elements
                if (e.target.closest('.annotation-form') ||
                    e.target.closest('.annotation-card')) return;

                var sel = window.getSelection();
                if (!sel || sel.isCollapsed) return;

                var range = sel.getRangeAt(0);
                var startBlock = self.findBlockElement(range.startContainer);
                var endBlock = self.findBlockElement(range.endContainer);

                if (!startBlock || !endBlock) return;

                var startIdx = self.blocks.indexOf(startBlock);
                var endIdx = self.blocks.indexOf(endBlock);
                if (startIdx < 0 || endIdx < 0) return;

                var lo = Math.min(startIdx, endIdx);
                var hi = Math.max(startIdx, endIdx);

                // Guard: if the form is open with unsaved text,
                // ask Swift for confirmation before replacing it.
                if (self.isFormVisible()) {
                    var ta = self.formElement
                        ? self.formElement.querySelector('textarea')
                        : null;
                    if (ta && ta.value.trim()) {
                        window.webkit.messageHandlers.annotation
                            .postMessage({
                                action: 'confirmDragReplace',
                                startIdx: lo,
                                endIdx: hi
                            });
                        sel.removeAllRanges();
                        return;
                    }
                }

                self.showFormForSelection(lo, hi);
                sel.removeAllRanges();
            });
        },

        findBlockElement(node) {
            var el = node.nodeType === 3 ? node.parentElement : node;
            while (el && !el.classList.contains('md-block')) {
                el = el.parentElement;
            }
            if (!el) return null;
            // Walk to leaf block (no md-block children)
            while (el.querySelector('.md-block')) {
                el = el.querySelector('.md-block');
            }
            return el;
        },

        showFormForSelection(startIdx, endIdx) {
            this.collapseExpanded();
            this.currentBlockIndex = endIdx;
            this.highlightStart = startIdx;
            this.highlightEnd = endIdx;
            this.updateHighlights();
            this.positionForm();
            this.formElement.style.display = '';

            var ta = this.formElement.querySelector('textarea');
            if (ta) { ta.value = ''; autoGrow(ta); }
            this.updateFormReference();
            requestAnimationFrame(function() {
                if (ta) ta.focus();
            });
        },

        restoreFormState(state) {
            if (!state || this.blocks.length === 0) return;
            var maxIdx = this.blocks.length - 1;

            // Only restore form visibility if it was visible (valid selection)
            if (state.formVisible && state.currentBlockIndex >= 0) {
                this.currentBlockIndex = Math.min(state.currentBlockIndex, maxIdx);
                this.highlightStart = Math.min(state.highlightStart || 0, maxIdx);
                this.highlightEnd = Math.min(state.highlightEnd || 0, maxIdx);
                this.updateHighlights();
                this.positionForm();
                this.formElement.style.display = '';
                this.updateFormReference();
                if (state.textareaValue) {
                    var ta = this.formElement.querySelector('textarea');
                    if (ta) { ta.value = state.textareaValue; autoGrow(ta); }
                }
            }
            // Restore expanded annotation after theme change
            if (state.expandedNumber != null) {
                this.expandAnnotation(state.expandedNumber);
            }
        },

        focusTextarea() {
            var ta = this.formElement ? this.formElement.querySelector('textarea') : null;
            if (ta) ta.focus();
        },

        // --- Highlighting ---

        updateHighlights() {
            var hs = this.highlightStart;
            var he = this.highlightEnd;
            this.blocks.forEach(function(block, i) {
                var inFormRange = hs >= 0 && he >= 0 && i >= hs && i <= he;
                var hasExpanded = block.classList.contains('annotation-expanded-highlight');
                // Yellow expanded highlight takes precedence over blue form highlight
                block.classList.toggle('annotation-highlight',
                    inFormRange && !hasExpanded);
            });
        },

        // --- Form Management ---

        createForm() {
            var form = document.createElement('div');
            form.className = 'annotation-form';
            form.id = 'annotation-form';
            form.style.display = 'none';
            form.innerHTML =
                '<div class="annotation-form-header">' +
                '<span class="annotation-form-ref"></span>' +
                '</div>' +
                '<textarea class="annotation-textarea" ' +
                'placeholder="Add annotation\\u2026 (\\u2318Enter to save \\u00b7 Esc to dismiss)" ' +
                'rows="1"></textarea>';

            var ta = form.querySelector('textarea');
            ta.addEventListener('focus', function() {
                AnnotationManager.collapseExpanded();
            });
            ta.addEventListener('input', function() { autoGrow(ta); });
            ta.addEventListener('keydown', function(e) {
                if (typeof EmojiAutocomplete !== 'undefined' &&
                    EmojiAutocomplete.handleKeyDown(ta, e)) {
                    return;
                }
                if (e.key === 'Enter' && e.metaKey) {
                    e.preventDefault();
                    AnnotationManager.submitCreate();
                }
            });

            if (typeof EmojiAutocomplete !== 'undefined') {
                EmojiAutocomplete.attach(ta);
            }

            this.formElement = form;
            document.body.appendChild(form);

            // ResizeObserver keeps spacer height in sync with form
            this.resizeObserver = new ResizeObserver(function() {
                AnnotationManager.syncAllPositions();
            });
            this.resizeObserver.observe(form);
        },

        positionForm(skipScroll, direction) {
            var targetBlock = this.blocks[this.highlightEnd];
            if (!targetBlock || !this.formElement) return;

            // Remove old form spacer
            this.removeSpacer(this.formSpacer, this.formSpacerRow);

            // Find insertion point: after target block + any card spacers
            var insertBefore = targetBlock.nextElementSibling;
            while (insertBefore && (
                insertBefore.classList.contains('annotation-spacer') ||
                insertBefore.classList.contains('annotation-spacer-row')
            )) {
                insertBefore = insertBefore.nextElementSibling;
            }

            // Create form spacer at insertion point
            var result = this.createSpacer(
                targetBlock.parentNode, insertBefore, 'form-spacer'
            );
            this.formSpacer = result.spacer;
            this.formSpacerRow = result.spacerRow;

            this.updateFormReference();
            this.syncAllPositions();
            if (!skipScroll) {
                if (direction) {
                    this.scrollFormIntoView(direction);
                } else {
                    this.formElement.scrollIntoView({
                        behavior: 'smooth',
                        block: 'nearest'
                    });
                }
            }
        },

        scrollFormIntoView(direction) {
            if (!this.formElement) return;
            var rect = this.formElement.getBoundingClientRect();
            var vh = window.innerHeight;

            // If form is completely off-screen, center it and bail out.
            // This prevents competing with the directional scrollBy below.
            if (rect.bottom < 0 || rect.top > vh) {
                this.formElement.scrollIntoView({
                    behavior: 'smooth',
                    block: 'center'
                });
                return;
            }

            // Directional margin: ensure lookahead space in travel direction
            var margin = vh * 0.35;

            if (direction === 'down') {
                var bottomSpace = vh - rect.bottom;
                if (bottomSpace < margin) {
                    window.scrollBy({
                        top: margin - bottomSpace,
                        behavior: 'smooth'
                    });
                }
            } else if (direction === 'up') {
                var topSpace = rect.top;
                if (topSpace < margin) {
                    window.scrollBy({
                        top: -(margin - topSpace),
                        behavior: 'smooth'
                    });
                }
            }
        },

        updateFormReference() {
            var range = this.getLineRange(this.highlightStart, this.highlightEnd);
            var lineRef = range.startLine === range.endLine
                ? 'line ' + range.startLine
                : 'lines ' + range.startLine + '\\u2013' + range.endLine;
            var ref = this.formElement.querySelector('.annotation-form-ref');
            if (ref) {
                ref.textContent = (this.itemLabel ? this.itemLabel + ': ' : '') + lineRef;
            }
        },

        getLineRange(startIdx, endIdx) {
            var startBlock = this.blocks[startIdx];
            var endBlock = this.blocks[endIdx];
            return {
                startLine: parseInt(startBlock.getAttribute('data-line-start')) || 0,
                endLine: parseInt(endBlock.getAttribute('data-line-end')) || 0
            };
        },

        // --- Annotation Cards ---

        renderAllAnnotations() {
            // Clean up any emoji popup for edit textareas being destroyed
            if (typeof EmojiAutocomplete !== 'undefined') {
                var editTas = document.querySelectorAll('.annotation-edit-textarea');
                editTas.forEach(function(ta) { EmojiAutocomplete.detach(ta); });
            }
            this.clearDeleteConfirmation();
            // Remove all existing card spacers and cards
            for (var num in this.cardSpacers) {
                var entry = this.cardSpacers[num];
                this.removeSpacer(entry.spacer, entry.spacerRow);
                if (this.resizeObserver && entry.card) {
                    this.resizeObserver.unobserve(entry.card);
                }
                if (entry.card && entry.card.parentNode) entry.card.remove();
            }
            this.cardSpacers = {};
            // Insert in reading order
            for (var i = 0; i < this.annotations.length; i++) {
                var ann = this.annotations[i];
                var html = this.annotationHTMLMap[ann.number] || '';
                this.insertCard(ann, html);
            }
            // Re-position form after cards (cards may have shifted it);
            // skip scrollIntoView — callers manage scroll explicitly
            if (this.formElement) this.positionForm(true);
            // Re-apply expanded line highlights (cards were rebuilt)
            if (this.expandedNumber !== null) {
                this.applyExpandedHighlight(this.expandedNumber);
            }
        },

        refreshAnnotationData(annotations) {
            this.annotations = annotations;
            this.renderAllAnnotations();
        },

        findBlockIndexForEndLine(endLine) {
            for (var i = this.blocks.length - 1; i >= 0; i--) {
                var blockEnd = parseInt(
                    this.blocks[i].getAttribute('data-line-end')
                );
                if (blockEnd <= endLine) return i;
            }
            return 0;
        },

        insertCard(annotation, renderedHTML) {
            var blockIdx = this.findBlockIndexForEndLine(annotation.end_line);
            var block = this.blocks[blockIdx];
            if (!block) return;

            var lineRef = annotation.start_line === annotation.end_line
                ? 'line ' + annotation.start_line
                : 'lines ' + annotation.start_line + '\\u2013' + annotation.end_line;

            var isExpanded = this.expandedNumber === annotation.number;
            var hasReview = !!annotation.review_number;

            // Build meta text: "#3" for unreviewed,
            // "#3 · Review #1" (pending) or "#3 · Review #1 · Mar 1, 2026" (processed)
            var metaText = '#' + annotation.number;
            if (hasReview) {
                metaText += ' \\u00B7 Review #' + annotation.review_number;
                if (annotation.review_reviewed_at) {
                    metaText += ' \\u00B7 ' + this.formatReviewDate(annotation.review_reviewed_at);
                }
            }

            // Only show edit/delete buttons for annotations not assigned to a review
            var actionsHTML = hasReview ? '' :
                '<span class="annotation-card-actions">' +
                    '<button class="annotation-btn-edit" title="Edit">' +
                        this.editIconSVG + '</button>' +
                    '<button class="annotation-btn-delete" title="Delete">' +
                        this.deleteIconSVG + '</button>' +
                '</span>';

            var card = document.createElement('div');
            card.className = 'annotation-card' + (isExpanded ? ' expanded' : '');
            card.setAttribute('data-number', annotation.number);
            card.innerHTML =
                '<div class="annotation-card-header">' +
                    '<span class="annotation-card-ref">' + lineRef + '</span>' +
                    '<span class="annotation-card-meta">' + metaText + '</span>' +
                    actionsHTML +
                '</div>' +
                '<div class="annotation-card-content' +
                    (isExpanded ? '' : ' collapsed') + '">' +
                    renderedHTML +
                '</div>' +
                '<span class="annotation-expand-hint"' +
                    (isExpanded ? ' style="display:none"' : '') +
                    '>Click to expand</span>';

            // Wire card-level click for expand/collapse
            var self = this;
            card.addEventListener('click', function(e) {
                if (e.target.closest('.annotation-card-actions') ||
                    e.target.closest('.annotation-edit-textarea')) return;
                self.expandAnnotation(annotation.number);
            });

            // Only wire edit/delete listeners when buttons exist
            if (!hasReview) {
                card.querySelector('.annotation-btn-edit').addEventListener(
                    'click', function(e) {
                        e.stopPropagation();
                        self.startEdit(annotation.number);
                    }
                );
                card.querySelector('.annotation-btn-delete').addEventListener(
                    'click', function(e) {
                        e.stopPropagation();
                        self.handleDeleteClick(annotation.number);
                    }
                );
            }

            // Create card spacer at inline position
            var insertBefore = block.nextElementSibling;
            while (insertBefore && (
                insertBefore.classList.contains('annotation-spacer') ||
                insertBefore.classList.contains('annotation-spacer-row')
            )) {
                insertBefore = insertBefore.nextElementSibling;
            }
            var result = this.createSpacer(
                block.parentNode, insertBefore, 'card-spacer'
            );

            // Append card to body and track
            document.body.appendChild(card);
            this.cardSpacers[annotation.number] = {
                spacer: result.spacer,
                spacerRow: result.spacerRow,
                card: card
            };
            if (this.resizeObserver) this.resizeObserver.observe(card);
        },

        expandAnnotation(number) {
            if (this.expandedNumber === number) {
                // Toggle off — collapse this annotation
                this.collapseExpanded();
                this.focusTextarea();
                return;
            }

            // Collapse any currently expanded annotation
            this.collapseExpanded();

            // Cancel any in-progress edit on a different annotation
            if (this.editingNumber !== null && this.editingNumber !== number) {
                this.cancelEdit();
            }

            // Expand the target card
            this.expandedNumber = number;
            var card = document.querySelector(
                '.annotation-card[data-number="' + number + '"]'
            );
            if (card) {
                card.classList.add('expanded');
                var content = card.querySelector('.annotation-card-content');
                if (content) content.classList.remove('collapsed');
                var hint = card.querySelector('.annotation-expand-hint');
                if (hint) hint.style.display = 'none';
                this.syncAllPositions();
                card.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
            }

            // Highlight the annotation's line range in yellow
            this.applyExpandedHighlight(number);
        },

        collapseExpanded() {
            if (this.expandedNumber === null) return;

            var card = document.querySelector(
                '.annotation-card[data-number="' + this.expandedNumber + '"]'
            );
            if (card) {
                card.classList.remove('expanded');
                var content = card.querySelector('.annotation-card-content');
                if (content) content.classList.add('collapsed');
                var hint = card.querySelector('.annotation-expand-hint');
                if (hint) hint.style.display = '';
            }

            this.clearExpandedHighlight();
            this.expandedNumber = null;
            // Re-apply blue form highlights (may have been suppressed)
            this.updateHighlights();
            this.syncAllPositions();
        },

        applyExpandedHighlight(number) {
            var ann = this.annotations.find(
                function(a) { return a.number === number; }
            );
            if (!ann) return;

            var startIdx = this.findBlockIndexForStartLine(ann.start_line);
            var endIdx = this.findBlockIndexForEndLine(ann.end_line);

            for (var i = startIdx; i <= endIdx; i++) {
                this.blocks[i].classList.add('annotation-expanded-highlight');
                // Remove blue form highlight where yellow takes precedence
                this.blocks[i].classList.remove('annotation-highlight');
            }
        },

        clearExpandedHighlight() {
            this.blocks.forEach(function(block) {
                block.classList.remove('annotation-expanded-highlight');
            });
        },

        findBlockIndexForStartLine(startLine) {
            for (var i = 0; i < this.blocks.length; i++) {
                var blockStart = parseInt(
                    this.blocks[i].getAttribute('data-line-start')
                );
                if (blockStart >= startLine) return i;
            }
            return this.blocks.length - 1;
        },

        // --- Spacer Management ---

        createSpacer(parent, insertBefore, className) {
            var spacer = document.createElement('div');
            spacer.className = 'annotation-spacer ' + className;
            spacer.style.height = '0px';

            var spacerRow = null;
            var parentTag = parent.tagName;
            if (parentTag === 'TBODY' || parentTag === 'THEAD') {
                spacerRow = document.createElement('tr');
                spacerRow.className = 'annotation-spacer-row';
                var td = document.createElement('td');
                td.setAttribute('colspan', '999');
                td.appendChild(spacer);
                spacerRow.appendChild(td);
                parent.insertBefore(spacerRow, insertBefore);
            } else {
                parent.insertBefore(spacer, insertBefore);
            }

            return { spacer: spacer, spacerRow: spacerRow };
        },

        removeSpacer(spacer, spacerRow) {
            if (spacerRow) spacerRow.remove();
            else if (spacer) spacer.remove();
        },

        syncAllPositions() {
            var scrollY = window.pageYOffset || document.documentElement.scrollTop;

            if (this.formSpacer && this.formElement) {
                this.formSpacer.style.height = this.formElement.offsetHeight + 'px';
                var rect = this.formSpacer.getBoundingClientRect();
                this.formElement.style.top = (rect.top + scrollY) + 'px';
            }
            for (var num in this.cardSpacers) {
                var entry = this.cardSpacers[num];
                if (entry.spacer && entry.card) {
                    entry.spacer.style.height = entry.card.offsetHeight + 'px';
                    var rect = entry.spacer.getBoundingClientRect();
                    entry.card.style.top = (rect.top + scrollY) + 'px';
                }
            }
        },

        // --- Editing ---

        startEdit(number) {
            if (this.editingNumber !== null) this.cancelEdit();
            // Ensure the card is expanded (without toggling off if already expanded)
            if (this.expandedNumber !== number) {
                this.expandAnnotation(number);
            }
            this.editingNumber = number;

            var card = document.querySelector(
                '.annotation-card[data-number="' + number + '"]'
            );
            if (!card) return;
            var contentDiv = card.querySelector('.annotation-card-content');
            var ann = this.annotations.find(function(a) { return a.number === number; });
            if (!ann || !contentDiv) return;

            // Store original HTML for cancel
            card.setAttribute('data-original-html', contentDiv.outerHTML);

            var ta = document.createElement('textarea');
            ta.className = 'annotation-edit-textarea';
            ta.value = ann.content;
            contentDiv.replaceWith(ta);

            autoGrow(ta);
            ta.addEventListener('input', function() { autoGrow(ta); });
            ta.addEventListener('keydown', function(e) {
                if (typeof EmojiAutocomplete !== 'undefined' &&
                    EmojiAutocomplete.handleKeyDown(ta, e)) {
                    return;
                }
                if (e.key === 'Enter' && e.metaKey) {
                    e.preventDefault();
                    AnnotationManager.submitUpdate(number);
                }
            });

            if (typeof EmojiAutocomplete !== 'undefined') {
                EmojiAutocomplete.attach(ta);
            }

            this.syncAllPositions();
            ta.focus();
        },

        cancelEdit() {
            if (this.editingNumber === null) return;
            var card = document.querySelector(
                '.annotation-card[data-number="' + this.editingNumber + '"]'
            );
            if (card) {
                var ta = card.querySelector('.annotation-edit-textarea');
                if (typeof EmojiAutocomplete !== 'undefined' && ta) {
                    EmojiAutocomplete.detach(ta);
                }
                var originalHTML = card.getAttribute('data-original-html');
                if (ta && originalHTML) {
                    var temp = document.createElement('div');
                    temp.innerHTML = originalHTML;
                    if (temp.firstChild) ta.replaceWith(temp.firstChild);
                }
                card.removeAttribute('data-original-html');
            }
            this.editingNumber = null;
            this.syncAllPositions();
        },

        // --- Communication with Swift ---

        submitCreate() {
            if (this.submitting) return;
            var ta = this.formElement.querySelector('textarea');
            var content = ta ? ta.value.trim() : '';
            if (!content) return;

            this.submitting = true;
            var range = this.getLineRange(this.highlightStart, this.highlightEnd);
            window.webkit.messageHandlers.annotation.postMessage({
                action: 'create',
                startLine: range.startLine,
                endLine: range.endLine,
                content: content
            });
        },

        submitUpdate(number) {
            if (this.submitting) return;
            var card = document.querySelector(
                '.annotation-card[data-number="' + number + '"]'
            );
            if (!card) return;
            var ta = card.querySelector('.annotation-edit-textarea');
            if (!ta) return;
            var content = ta.value.trim();
            if (!content) return;

            this.submitting = true;
            window.webkit.messageHandlers.annotation.postMessage({
                action: 'update',
                number: number,
                content: content
            });
        },

        handleDeleteClick(number) {
            if (this.deleting) return;
            if (this.confirmingDeleteNumber === number) {
                // Reject clicks too close to arming — this
                // catches the second click of a double-click
                // regardless of whether btn.disabled worked.
                var elapsed = Date.now() - this.confirmArmedAt;
                if (elapsed < 500) return;
                this.deleting = true;
                this.clearDeleteConfirmation();
                this.requestDelete(number);
            } else {
                this.showDeleteConfirmation(number);
            }
        },

        showDeleteConfirmation(number) {
            this.clearDeleteConfirmation();
            this.confirmingDeleteNumber = number;
            this.confirmArmedAt = Date.now();

            var btn = document.querySelector(
                '.annotation-card[data-number="' + number + '"] .annotation-btn-delete'
            );
            if (!btn) return;
            btn.classList.add('confirming');
            btn.textContent = 'Are you sure?';

            // Auto-revert after 5 seconds
            this.confirmDeleteTimer = setTimeout(function() {
                AnnotationManager.clearDeleteConfirmation();
            }, 5000);
        },

        clearDeleteConfirmation() {
            if (this.confirmDeleteTimer) {
                clearTimeout(this.confirmDeleteTimer);
                this.confirmDeleteTimer = null;
            }
            this.confirmArmedAt = null;
            var number = this.confirmingDeleteNumber;
            if (number === null) return;
            this.confirmingDeleteNumber = null;

            var btn = document.querySelector(
                '.annotation-card[data-number="' + number + '"] .annotation-btn-delete'
            );
            if (!btn) return;
            btn.classList.remove('confirming');
            btn.innerHTML = this.deleteIconSVG;
        },

        requestDelete(number) {
            window.webkit.messageHandlers.annotation.postMessage({
                action: 'delete',
                number: number
            });
        },

        // --- Callbacks from Swift ---

        annotationCreated(data) {
            this.submitting = false;
            var scrollY = window.pageYOffset || document.documentElement.scrollTop;

            this.annotations.push(data.annotation);
            this.annotationHTMLMap[data.annotation.number] = data.renderedHTML;

            // Re-sort in reading order
            this.annotations.sort(function(a, b) {
                return (a.start_line - b.start_line) ||
                       (a.end_line - b.end_line) ||
                       (a.number - b.number);
            });

            this.renderAllAnnotations();

            // Hide form and clear highlights after creation
            this.dismissForm();

            // Restore scroll to undo any browser clamping from DOM
            // teardown, then nudge viewport if the new card pushed
            // the form below the fold.
            window.scrollTo(0, scrollY);
            this.formElement.scrollIntoView({ block: 'nearest' });
        },

        annotationUpdated(data) {
            this.submitting = false;
            var scrollY = window.pageYOffset || document.documentElement.scrollTop;

            var idx = this.annotations.findIndex(
                function(a) { return a.number === data.annotation.number; }
            );
            if (idx >= 0) this.annotations[idx] = data.annotation;
            this.annotationHTMLMap[data.annotation.number] = data.renderedHTML;
            this.editingNumber = null;
            this.renderAllAnnotations();

            window.scrollTo(0, scrollY);
        },

        annotationDeleted(number) {
            this.deleting = false;
            var scrollY = window.pageYOffset || document.documentElement.scrollTop;

            if (this.expandedNumber === number) {
                this.collapseExpanded();
            }
            this.annotations = this.annotations.filter(
                function(a) { return a.number !== number; }
            );
            delete this.annotationHTMLMap[number];
            this.renderAllAnnotations();

            window.scrollTo(0, scrollY);
        },

        // --- Escape Context ---

        isFormVisible() {
            return this.formElement &&
                this.formElement.style.display !== 'none';
        },

        focusForm() {
            if (!this.isFormVisible()) return;
            var ta = this.formElement
                ? this.formElement.querySelector('textarea')
                : null;
            if (ta) ta.focus();
        },

        getEscapeContext() {
            // Emoji popup takes highest priority — dismiss it first
            if (typeof EmojiAutocomplete !== 'undefined') {
                var formTa = this.formElement
                    ? this.formElement.querySelector('textarea') : null;
                if (formTa && EmojiAutocomplete.isActive(formTa)) return 'emojiPopup';
                if (this.editingNumber !== null) {
                    var editTa = document.querySelector(
                        '.annotation-card[data-number="' + this.editingNumber
                        + '"] .annotation-edit-textarea'
                    );
                    if (editTa && EmojiAutocomplete.isActive(editTa)) return 'emojiPopup';
                }
            }
            if (this.editingNumber !== null) {
                // Check if content has changed from original
                var card = document.querySelector(
                    '.annotation-card[data-number="' + this.editingNumber + '"]'
                );
                if (card) {
                    var ta = card.querySelector('.annotation-edit-textarea');
                    var ann = this.annotations.find(function(a) {
                        return a.number === AnnotationManager.editingNumber;
                    });
                    if (ta && ann && ta.value !== ann.content) return 'editing';
                }
                // No changes — just cancel directly
                this.cancelEdit();
                return '__consumed__';
            }
            if (this.expandedNumber !== null) return 'expanded';
            if (this.isFormVisible()) {
                var ta = this.formElement.querySelector('textarea');
                if (ta && ta.value.trim()) return 'formHasText';
                return 'formVisible';
            }
            return 'close';
        },

        dismissForm() {
            if (this.formElement) {
                var ta = this.formElement.querySelector('textarea');
                if (ta) { ta.value = ''; autoGrow(ta); }
                this.formElement.style.display = 'none';
            }
            // Remove form spacer so it doesn't take up space
            this.removeSpacer(this.formSpacer, this.formSpacerRow);
            this.formSpacer = null;
            this.formSpacerRow = null;
            this.highlightStart = -1;
            this.highlightEnd = -1;
            this.currentBlockIndex = -1;
            this.updateHighlights();
            this.syncAllPositions();
        },

        // --- Date Formatting ---

        formatReviewDate(dateStr) {
            // Parse SQLite "YYYY-MM-DD HH:MM:SS" or ISO 8601 timestamps
            var d = new Date(dateStr.replace(' ', 'T') + (dateStr.indexOf('Z') < 0 && dateStr.indexOf('+') < 0 ? 'Z' : ''));
            if (isNaN(d.getTime())) return 'reviewed';
            var months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
            return months[d.getMonth()] + ' ' + d.getDate() + ', ' + d.getFullYear();
        },

        // --- Form State (for theme-change recovery) ---

        getFormState() {
            var ta = this.formElement
                ? this.formElement.querySelector('textarea') : null;
            return {
                currentBlockIndex: this.currentBlockIndex,
                highlightStart: this.highlightStart,
                highlightEnd: this.highlightEnd,
                formVisible: this.isFormVisible(),
                textareaValue: ta ? ta.value : '',
                expandedNumber: this.expandedNumber
            };
        }
    };

    function handleFileDrop(paths) {
        var ta = null;
        if (AnnotationManager.formElement
            && AnnotationManager.formElement
                .style.display !== 'none') {
            ta = AnnotationManager.formElement
                .querySelector('textarea');
        }
        if (!ta
            && AnnotationManager.editingNumber
                !== null) {
            ta = document.querySelector(
                '.annotation-card[data-number="'
                + AnnotationManager.editingNumber
                + '"] .annotation-edit-textarea'
            );
        }
        if (!ta) return;

        var text = paths.map(function(p) {
            return '[' + p + ']';
        }).join(' ');

        var start = ta.selectionStart;
        var end = ta.selectionEnd;
        var before = ta.value.substring(0, start);
        var after = ta.value.substring(end);

        var prefix = '';
        if (before.length > 0
            && before[before.length - 1] !== '\\n') {
            prefix = '\\n';
        }
        var suffix = '\\n';

        ta.value = before + prefix + text
            + suffix + after;

        var newPos = start + prefix.length
            + text.length + suffix.length;
        ta.selectionStart = newPos;
        ta.selectionEnd = newPos;

        ta.dispatchEvent(new Event('input'));
        ta.focus();
    }
    </script>
    <script>\(emojiDataJS)</script>
    <script>\(emojiAutocompleteJS)</script>
    <script>\(mermaidJS)</script>
    <script>
    if (typeof mermaid !== 'undefined'
        && document.querySelector('.mermaid')) {
        mermaid.initialize({
            startOnLoad: false,
            theme: '\(themeClass)' === 'dark'
                ? 'dark' : 'default',
            securityLevel: 'loose',
        });
        mermaid.run();
    }
    </script>
    </body>
    </html>
    """
}

// MARK: - Line-Anchored HTML Visitor

/// Walks the swift-markdown AST and emits HTML with `data-line-start`
/// and `data-line-end` attributes on each block element.
///
/// This gives every rendered block a direct link back to its source
/// line range, which is the foundation for line-by-line annotation
/// (similar to GitHub PR review comments).
struct LineAnchoredHTMLVisitor: MarkupVisitor {
    typealias Result = String

    /// Tracks table nesting so list items inside table cells emit bare
    /// `<li>` (no md-block class) — the table row is the navigable unit.
    private var insideTable: Bool = false

    // MARK: - Default / Document

    mutating func defaultVisit(_ markup: any Markup) -> String {
        var result = ""
        for child in markup.children {
            result += visit(child)
        }
        return result
    }

    mutating func visitDocument(_ document: Document) -> String {
        defaultVisit(document)
    }

    // MARK: - Block Elements (line-anchored)

    func visitParagraph(_ paragraph: Paragraph) -> String {
        let inner = visitChildren(paragraph)
        return wrapBlock("p", markup: paragraph, inner: inner)
    }

    func visitHeading(_ heading: Heading) -> String {
        let tag = "h\(heading.level)"
        let inner = visitChildren(heading)
        return wrapBlock(tag, markup: heading, inner: inner)
    }

    func visitCodeBlock(_ codeBlock: CodeBlock) -> String {
        // Mermaid code blocks render as diagrams
        // (not line-annotatable)
        if codeBlock.language?.lowercased()
            == "mermaid"
        {
            let escaped = escapeHTML(codeBlock.code)
            let inner = "<div class=\"mermaid\">"
                + "\(escaped)</div>"
            return wrapBlock(
                "div", markup: codeBlock,
                inner: inner
            )
        }

        let langAttr: String
        if let lang = codeBlock.language,
           !lang.isEmpty
        {
            langAttr = " class=\"language-"
                + "\(escapeHTML(lang))\""
        } else {
            langAttr = ""
        }

        // Content lines start after the opening
        // fence (```). Each line becomes its own
        // md-block so it can be individually
        // selected and annotated.
        let fenceStart =
            codeBlock.range?.lowerBound.line ?? 0
        let contentStartLine = fenceStart + 1

        var lines = codeBlock.code.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        // Drop trailing empty line from fence
        // parsing
        if let last = lines.last, last.isEmpty {
            lines = lines.dropLast()
        }

        var linesDivs = ""
        for (idx, line) in lines.enumerated() {
            let lineNum = contentStartLine + idx
            let raw = String(line)
            // Empty lines need &nbsp; so the div
            // maintains its line height instead of
            // collapsing to zero.
            let content = raw.isEmpty
                ? "&nbsp;"
                : escapeHTML(raw)
            linesDivs += "<div class=\"md-block"
                + " code-line\""
                + " data-line-start=\"\(lineNum)\""
                + " data-line-end=\"\(lineNum)\">"
                + "<code\(langAttr)>\(content)"
                + "</code></div>"
        }

        // Outer <pre> provides visual code block
        // styling but is NOT an md-block — the
        // individual code-line divs inside are
        // the selectable annotation units.
        let fenceEnd =
            codeBlock.range?.upperBound.line ?? 0
        return "<pre class=\"code-block-wrapper\""
            + " data-line-start=\"\(fenceStart)\""
            + " data-line-end=\"\(fenceEnd)\">"
            + "\(linesDivs)</pre>\n"
    }

    func visitBlockQuote(
        _ blockQuote: BlockQuote
    ) -> String {
        // Children (paragraphs, lists, etc.) are
        // already wrapped as their own md-blocks by
        // their respective visit methods. The outer
        // <blockquote> provides visual styling but
        // is NOT an md-block — the children inside
        // are the selectable annotation units.
        let inner = visitChildren(blockQuote)
        let start =
            blockQuote.range?.lowerBound.line ?? 0
        let end =
            blockQuote.range?.upperBound.line ?? 0
        return "<blockquote"
            + " data-line-start=\"\(start)\""
            + " data-line-end=\"\(end)\">"
            + "\(inner)</blockquote>\n"
    }

    func visitOrderedList(_ orderedList: OrderedList) -> String {
        let inner = visitChildren(orderedList)
        return wrapBlock("ol", markup: orderedList, inner: inner)
    }

    func visitUnorderedList(_ unorderedList: UnorderedList) -> String {
        let inner = visitChildren(unorderedList)
        return wrapBlock("ul", markup: unorderedList, inner: inner)
    }

    func visitListItem(_ listItem: ListItem) -> String {
        let inner = visitChildren(listItem)
        if insideTable {
            return "<li>\(inner)</li>\n"
        }
        return wrapBlock("li", markup: listItem, inner: inner)
    }

    func visitThematicBreak(_ thematicBreak: ThematicBreak) -> String {
        return lineAttrs(thematicBreak, tag: "hr")
    }

    func visitHTMLBlock(_ html: HTMLBlock) -> String {
        return wrapBlock("div", markup: html, inner: html.rawHTML)
    }

    mutating func visitTable(
        _ table: Markdown.Table
    ) -> String {
        insideTable = true

        // Each row becomes its own md-block so it
        // can be individually annotated. The outer
        // <table> wrapper provides visual styling
        // but is NOT an md-block.
        var html = "<table>\n"

        // Header row as its own md-block <tr>
        let headAttrs = lineAttrsString(table.head)
        html += "<thead><tr\(headAttrs)>"
        for cell in table.head.cells {
            html += "<th>"
                + "\(visitChildren(cell))</th>"
        }
        html += "</tr></thead>\n"

        // Body rows — each as its own md-block <tr>
        html += "<tbody>\n"
        for row in table.body.rows {
            let rowAttrs = lineAttrsString(row)
            html += "<tr\(rowAttrs)>"
            for cell in row.cells {
                html += "<td>"
                    + "\(visitChildren(cell))"
                    + "</td>"
            }
            html += "</tr>\n"
        }
        html += "</tbody>\n"
        html += "</table>\n"

        insideTable = false

        // Outer div is NOT an md-block — the
        // individual <tr> rows inside are the
        // selectable annotation units.
        let start =
            table.range?.lowerBound.line ?? 0
        let end =
            table.range?.upperBound.line ?? 0
        return "<div class=\"table-wrapper\""
            + " data-line-start=\"\(start)\""
            + " data-line-end=\"\(end)\">"
            + "\(html)</div>\n"
    }

    // MARK: - Inline Elements

    func visitText(_ text: Markdown.Text) -> String {
        return escapeHTML(text.string)
    }

    func visitEmphasis(_ emphasis: Emphasis) -> String {
        return "<em>\(visitChildren(emphasis))</em>"
    }

    func visitStrong(_ strong: Strong) -> String {
        return "<strong>\(visitChildren(strong))</strong>"
    }

    func visitStrikethrough(_ strikethrough: Strikethrough) -> String {
        return "<del>\(visitChildren(strikethrough))</del>"
    }

    func visitInlineCode(_ inlineCode: InlineCode) -> String {
        return "<code>\(escapeHTML(inlineCode.code))</code>"
    }

    func visitLink(_ link: Markdown.Link) -> String {
        let dest = link.destination ?? ""
        return "<a href=\"\(escapeHTML(dest))\">\(visitChildren(link))</a>"
    }

    func visitImage(_ image: Markdown.Image) -> String {
        let src = image.source ?? ""
        let alt = image.plainText
        return "<img src=\"\(escapeHTML(src))\" alt=\"\(escapeHTML(alt))\">"
    }

    func visitSoftBreak(_ softBreak: SoftBreak) -> String {
        return "\n"
    }

    func visitLineBreak(_ lineBreak: LineBreak) -> String {
        return "<br>\n"
    }

    func visitInlineHTML(_ inlineHTML: InlineHTML) -> String {
        return inlineHTML.rawHTML
    }

    // MARK: - Helpers

    /// Visit all children and concatenate their results.
    private func visitChildren(_ markup: any Markup) -> String {
        var visitor = self
        var result = ""
        for child in markup.children {
            result += visitor.visit(child)
        }
        return result
    }

    /// Wrap content in a block tag with line anchor attributes.
    private func wrapBlock(_ tag: String, markup: any Markup, inner: String) -> String {
        let attrs = lineAttrsString(markup)
        return "<\(tag)\(attrs)>\(inner)</\(tag)>\n"
    }

    /// Generate a self-closing tag with line attributes (e.g., <hr>).
    private func lineAttrs(_ markup: any Markup, tag: String) -> String {
        let attrs = lineAttrsString(markup)
        return "<\(tag)\(attrs)>\n"
    }

    /// Build the data-line-start/data-line-end attribute string.
    private func lineAttrsString(_ markup: any Markup) -> String {
        guard let range = markup.range else { return " class=\"md-block\"" }
        let start = range.lowerBound.line
        let end = range.upperBound.line
        return " class=\"md-block\" data-line-start=\"\(start)\" data-line-end=\"\(end)\""
    }

    /// Escape HTML special characters.
    private func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
