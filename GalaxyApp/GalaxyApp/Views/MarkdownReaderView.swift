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

                let initJS = buildAnnotationInitJS(
                    anchorType: "line_range",
                    blockSelector: ".md-block",
                    lineAttr: "data-line-start",
                    endLineAttr: "data-line-end",
                    refPrefix: "Line",
                    itemLabel: label,
                    annotations: annotations,
                    htmlMap: htmlMap
                )
                webView.evaluateJavaScript(initJS)

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

    /* --- Annotation + Emoji styles (shared) --- */
    \(annotationCSS)
    </style>
    <style>\(highlightCSS)</style>
    </head>
    <body class="\(themeClass)">
    \(bodyHTML)
    <script>\(highlightJS)</script>
    <script>if(typeof hljs !== 'undefined') hljs.highlightAll();</script>
    <script>\(annotationManagerJS)</script>
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
