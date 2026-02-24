import Foundation
import Markdown

/// Renders annotation markdown content to HTML for display in
/// annotation cards inside the WKWebView snapshot reader.
///
/// Differs from LineAnchoredHTMLVisitor:
/// - No line anchoring (no data-line-start/end, no md-block class)
/// - Soft breaks render as `<br>` (GFM-style line breaks)
/// - Text nodes auto-link bare URLs
struct AnnotationHTMLVisitor: MarkupVisitor {
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

    // MARK: - Block Elements

    func visitParagraph(_ paragraph: Paragraph) -> String {
        "<p>\(visitChildren(paragraph))</p>\n"
    }

    func visitHeading(_ heading: Heading) -> String {
        let tag = "h\(heading.level)"
        return "<\(tag)>\(visitChildren(heading))</\(tag)>\n"
    }

    func visitCodeBlock(_ codeBlock: CodeBlock) -> String {
        let escaped = escapeHTML(codeBlock.code)
        let langAttr: String
        if let lang = codeBlock.language, !lang.isEmpty {
            langAttr = " class=\"language-\(escapeHTML(lang))\""
        } else {
            langAttr = ""
        }
        return "<pre><code\(langAttr)>\(escaped)</code></pre>\n"
    }

    func visitBlockQuote(_ blockQuote: BlockQuote) -> String {
        "<blockquote>\(visitChildren(blockQuote))</blockquote>\n"
    }

    func visitOrderedList(_ orderedList: OrderedList) -> String {
        "<ol>\(visitChildren(orderedList))</ol>\n"
    }

    func visitUnorderedList(_ unorderedList: UnorderedList) -> String {
        "<ul>\(visitChildren(unorderedList))</ul>\n"
    }

    func visitListItem(_ listItem: ListItem) -> String {
        "<li>\(visitChildren(listItem))</li>\n"
    }

    func visitThematicBreak(_ thematicBreak: ThematicBreak) -> String {
        "<hr>\n"
    }

    func visitHTMLBlock(_ html: HTMLBlock) -> String {
        html.rawHTML
    }

    func visitTable(_ table: Markdown.Table) -> String {
        var html = "<table>\n<thead><tr>"
        for cell in table.head.cells {
            html += "<th>\(visitChildren(cell))</th>"
        }
        html += "</tr></thead>\n<tbody>\n"
        for row in table.body.rows {
            html += "<tr>"
            for cell in row.cells {
                html += "<td>\(visitChildren(cell))</td>"
            }
            html += "</tr>\n"
        }
        html += "</tbody>\n</table>\n"
        return html
    }

    // MARK: - Inline Elements

    func visitText(_ text: Markdown.Text) -> String {
        let escaped = escapeHTML(text.string)
        return autoLinkURLs(escaped)
    }

    func visitEmphasis(_ emphasis: Emphasis) -> String {
        "<em>\(visitChildren(emphasis))</em>"
    }

    func visitStrong(_ strong: Strong) -> String {
        "<strong>\(visitChildren(strong))</strong>"
    }

    func visitStrikethrough(_ strikethrough: Strikethrough) -> String {
        "<del>\(visitChildren(strikethrough))</del>"
    }

    func visitInlineCode(_ inlineCode: InlineCode) -> String {
        "<code>\(escapeHTML(inlineCode.code))</code>"
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
        "<br>\n"
    }

    func visitLineBreak(_ lineBreak: LineBreak) -> String {
        "<br>\n"
    }

    func visitInlineHTML(_ inlineHTML: InlineHTML) -> String {
        inlineHTML.rawHTML
    }

    // MARK: - Helpers

    private func visitChildren(_ markup: any Markup) -> String {
        var visitor = self
        var result = ""
        for child in markup.children {
            result += visitor.visit(child)
        }
        return result
    }

    private func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Replace bare URLs in already-escaped text with clickable links.
    private func autoLinkURLs(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"(https?://[^\s<&]+)"#
        ) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(
            in: text, range: range,
            withTemplate: #"<a href="$1">$1</a>"#
        )
    }
}

// MARK: - Public Rendering Function

/// Render annotation markdown content to an HTML fragment.
func renderAnnotationHTML(_ source: String) -> String {
    let document = Document(parsing: source)
    var visitor = AnnotationHTMLVisitor()
    return visitor.visit(document)
}
