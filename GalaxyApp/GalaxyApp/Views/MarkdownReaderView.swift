import SwiftUI
import WebKit
import Markdown
import Galactic

/// How this reader anchors annotations into its markup.
///
/// One `.md-block` can span several source lines — a fenced block, a table
/// row — so the span is carried by a pair of attributes rather than one.
let markdownAnchoring = ReaderAnchoring.lines(
    selector: ".md-block",
    lineAttr: "data-line-start",
    endLineAttr: "data-line-end"
)

// AnnotationMessage enum is in AnnotationSupport.swift

// MARK: - MarkdownReaderView

/// Renders markdown content in a themed WKWebView with source-line
/// anchored blocks and inline annotation support.
///
/// The Coordinator acts as both WKScriptMessageHandler (receiving JS
/// messages) and WKNavigationDelegate (injecting annotations after
/// page load). The webViewRef binding exposes the WKWebView so the
/// parent view can call evaluateJavaScript for annotation actions.
struct MarkdownReaderView: View {
    let markdown: String
    let isDark: Bool
    let annotations: [any ReaderAnnotation]
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
    // Absolute path of the file this artifact was created
    // from, when there was one. Used only to build a
    // copy-able reference; nothing about annotations
    // depends on it.
    var referencePath: String? = nil

    var body: some View {
        ReaderHostView(
            isDark: isDark,
            // Unlike the other readers this one's content can change under
            // it, so the source is part of what the page is built from. It
            // used to decide by rendering the document and comparing the
            // hash of the result — which meant building the page in full on
            // every pass in order to find out whether it needed building.
            reloadToken: [
                markdown.hashValue,
                isDark ? 1 : 0,
                annotationsEnabled ? 1 : 0,
            ],
            document: {
                renderMarkdownToHTML(markdown, isDark: isDark)
            },
            annotationInitJS: { formState in
                // A host can suppress the whole layer — a preview with
                // nothing to annotate against. Returning nothing installs
                // nothing, rather than installing a manager with no data.
                guard annotationsEnabled else { return "" }
                return buildAnnotationInitJS(
                    anchoring: markdownAnchoring,
                    itemLabel: itemLabel,
                    annotations: annotations,
                    htmlMap: annotationHTMLMap,
                    artifactContent: markdown,
                    referencePath: referencePath,
                    restoringFormState: formState
                )
            },
            baseURL: URL(string: "galaxy://\(baseUrlName)"),
            webView: $webViewRef,
            onAnnotationMessage: onAnnotationMessage,
            isInspectable: true
        )
    }
}

// MARK: - Rendering Pipeline

/// Parse markdown with swift-markdown and emit line-anchored HTML.
func renderMarkdownToHTML(_ source: String, isDark: Bool) -> String {
    let document = Document(parsing: source)
    var visitor = LineAnchoredHTMLVisitor()
    let bodyHTML = visitor.visit(document)

    let hjsContent = ReaderAssets.highlightJS
    let themeCSS = ReaderAssets.highlightThemeCSS(isDark: isDark)

    return buildFullHTML(
        bodyHTML: bodyHTML,
        highlightJS: hjsContent,
        highlightCSS: themeCSS,
        isDark: isDark
    )
}

// emojiDataJS and emojiAutocompleteJS are in
// AnnotationSupport.swift


/// Build a complete HTML document with embedded styles, highlight.js,
/// and the AnnotationManager JavaScript module.
private func buildFullHTML(
    bodyHTML: String,
    highlightJS: String,
    highlightCSS: String,
    isDark: Bool
) -> String {
    let theme = ReaderTheme.standard(isDark: isDark)

    return ReaderDocument.render(
        theme: theme,
        title: "Galaxy Snapshot Reader",
        fontSize: "14px",
        lineHeight: "1.6",
        css: """
        /* Four properties this reader's rules use that the shared card
           variables do not define. Derived from the palette rather than
           restated, so a change to the border colour reaches all three of
           the places that borrow it. */
        :root {
            color-scheme: light dark;
            --blockquote-border: \(theme.border);
            --table-border: \(theme.border);
            --link-color: \(theme.accent);
            --hr-color: \(theme.border);
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
        \(highlightCSS)
        """,
        body: """
        \(bodyHTML)
        """,
        scriptsBeforeCards: """
        \(highlightJS)
        if (typeof hljs !== 'undefined') hljs.highlightAll();
        """,
        // Diagrams render after the cards install. Unlike the standalone
        // diagram reader, a fence here is one block among many and the
        // anchors around it do not depend on its final size.
        scriptsAfterCards: """
        \(ReaderAssets.mermaidJS)
        if (typeof mermaid !== 'undefined'
            && document.querySelector('.mermaid')) {
            mermaid.initialize({
                startOnLoad: false,
                theme: \(isDark ? "'dark'" : "'default'"),
                securityLevel: 'loose',
            });
            mermaid.run();
        }
        """
    )
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
            let escaped = HTMLEscape.text(codeBlock.code)
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
                + "\(HTMLEscape.text(lang))\""
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
                : HTMLEscape.text(raw)
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
        return HTMLEscape.text(text.string)
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
        return "<code>\(HTMLEscape.text(inlineCode.code))</code>"
    }

    func visitLink(_ link: Markdown.Link) -> String {
        let dest = link.destination ?? ""
        return "<a href=\"\(HTMLEscape.text(dest))\">\(visitChildren(link))</a>"
    }

    func visitImage(_ image: Markdown.Image) -> String {
        let src = image.source ?? ""
        let alt = image.plainText
        return "<img src=\"\(HTMLEscape.text(src))\" alt=\"\(HTMLEscape.text(alt))\">"
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

}
