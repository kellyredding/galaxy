import SwiftUI
import WebKit
import Markdown

/// Renders markdown content in a themed WKWebView with source-line
/// anchored blocks for future annotation support.
///
/// Each block-level element gets `data-line-start` and `data-line-end`
/// attributes from the swift-markdown AST's SourceRange, giving
/// annotation line anchors for free without a future retrofit.
struct MarkdownReaderView: NSViewRepresentable {
    let markdown: String
    let isDark: Bool

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let html = renderMarkdownToHTML(markdown, isDark: isDark)
        let htmlHash = html.hashValue
        if context.coordinator.lastHTMLHash != htmlHash {
            context.coordinator.lastHTMLHash = htmlHash
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        var lastHTMLHash: Int = 0
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

/// Build a complete HTML document with embedded styles and highlight.js.
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
    </style>
    <style>\(highlightCSS)</style>
    </head>
    <body class="\(themeClass)">
    \(bodyHTML)
    <script>\(highlightJS)</script>
    <script>if(typeof hljs !== 'undefined') hljs.highlightAll();</script>
    </body>
    </html>
    """
}

// MARK: - Line-Anchored HTML Visitor

/// Walks the swift-markdown AST and emits HTML with `data-line-start`
/// and `data-line-end` attributes on each block element.
///
/// This gives every rendered block a direct link back to its source
/// line range, which is the foundation for future line-by-line
/// annotation (similar to GitHub PR review comments).
struct LineAnchoredHTMLVisitor: MarkupVisitor {
    typealias Result = String

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
        let escaped = escapeHTML(codeBlock.code)
        let langAttr: String
        if let lang = codeBlock.language, !lang.isEmpty {
            langAttr = " class=\"language-\(escapeHTML(lang))\""
        } else {
            langAttr = ""
        }
        let inner = "<pre><code\(langAttr)>\(escaped)</code></pre>"
        return wrapBlock("div", markup: codeBlock, inner: inner)
    }

    func visitBlockQuote(_ blockQuote: BlockQuote) -> String {
        let inner = visitChildren(blockQuote)
        return wrapBlock("blockquote", markup: blockQuote, inner: inner)
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
        return "<li>\(inner)</li>\n"
    }

    func visitThematicBreak(_ thematicBreak: ThematicBreak) -> String {
        return lineAttrs(thematicBreak, tag: "hr")
    }

    func visitHTMLBlock(_ html: HTMLBlock) -> String {
        return wrapBlock("div", markup: html, inner: html.rawHTML)
    }

    func visitTable(_ table: Markdown.Table) -> String {
        var html = "<table>\n"

        // Header
        html += "<thead><tr>"
        for cell in table.head.cells {
            html += "<th>\(visitChildren(cell))</th>"
        }
        html += "</tr></thead>\n"

        // Body rows
        html += "<tbody>\n"
        for row in table.body.rows {
            html += "<tr>"
            for cell in row.cells {
                html += "<td>\(visitChildren(cell))</td>"
            }
            html += "</tr>\n"
        }
        html += "</tbody>\n"
        html += "</table>\n"

        return wrapBlock("div", markup: table, inner: html)
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
