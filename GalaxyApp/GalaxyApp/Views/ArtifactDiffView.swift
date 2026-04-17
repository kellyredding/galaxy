import SwiftUI
import WebKit

// MARK: - Gdiff JSON Models

/// Top-level `.gdiff` document emitted by `galaxy-diff
/// capture`. Contains metadata plus per-file entries with
/// full before/after contents and parsed hunk data.
struct GdiffDocument: Codable {
    let version: Int
    let metadata: GdiffMetadata
    let files: [GdiffFile]
}

struct GdiffMetadata: Codable {
    let refFrom: String
    let refTo: String
    let branch: String
    let repo: String
    let createdAt: String
    let summary: String

    enum CodingKeys: String, CodingKey {
        case refFrom = "ref_from"
        case refTo = "ref_to"
        case branch, repo
        case createdAt = "created_at"
        case summary
    }
}

struct GdiffFile: Codable {
    let path: String
    let oldPath: String?
    let status: String
    let language: String?
    let before: String?
    let after: String?
    let hunks: [GdiffHunk]

    enum CodingKeys: String, CodingKey {
        case path
        case oldPath = "old_path"
        case status, language, before, after, hunks
    }
}

struct GdiffHunk: Codable {
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    let lines: [GdiffLine]

    enum CodingKeys: String, CodingKey {
        case oldStart = "old_start"
        case oldCount = "old_count"
        case newStart = "new_start"
        case newCount = "new_count"
        case lines
    }
}

struct GdiffLine: Codable {
    let type: String   // "context", "add", "delete"
    let oldNo: Int?
    let newNo: Int?
    let content: String

    enum CodingKeys: String, CodingKey {
        case type
        case oldNo = "old_no"
        case newNo = "new_no"
        case content
    }
}

// MARK: - ArtifactDiffView

/// Renders .gdiff structured diff files as annotatable
/// file cards with syntax highlighting and diff overlay.
/// Each file card shows the full "after" contents
/// (or "before" for deleted files) with hunk lines
/// shaded green/red. Character-level changes within
/// modified line pairs get a darker highlight.
///
/// Uses the same WKWebView + AnnotationCoordinator
/// pattern as ArtifactSourceView, with a global
/// sequential `data-line` counter so line_range
/// annotations work unchanged.
struct ArtifactDiffView: NSViewRepresentable {
    let content: String
    let isDark: Bool
    let annotations: [ArtifactAnnotation]
    let annotationHTMLMap: [Int32: String]
    let itemLabel: String
    @Binding var webViewRef: WKWebView?
    var onAnnotationMessage:
        ((AnnotationMessage) -> Void)?

    func makeNSView(
        context: Context
    ) -> SilentFunctionKeyWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(
            context.coordinator, name: "annotation"
        )
        let webView = SilentFunctionKeyWebView(
            frame: .zero, configuration: config
        )
        webView.setValue(
            false, forKey: "drawsBackground"
        )
        webView.navigationDelegate =
            context.coordinator

        webView.wantsLayer = true
        webView.layer?.backgroundColor =
            isDark
            ? NSColor.black.cgColor
            : NSColor.white.cgColor

        let activeAnns = annotations.filter {
            !$0.stale && (
                $0.anchorData.type == .lineRange
                    || $0.anchorData.type == .diffRange
            )
        }
        let initJS = buildAnnotationInitJS(
            anchorType: "line_range",
            blockSelector: ".code-line",
            lineAttr: "data-line",
            refPrefix: "Line",
            itemLabel: itemLabel,
            annotations: activeAnns,
            htmlMap: annotationHTMLMap
        )
        context.coordinator.pendingInitJS = initJS
        context.coordinator.onAnnotationMessage =
            onAnnotationMessage

        let html = buildDiffHTML(
            content: content,
            isDark: isDark
        )
        webView.loadHTMLString(
            html,
            baseURL: URL(
                string: "galaxy://artifact-reader"
            )
        )

        DispatchQueue.main.async {
            webViewRef = webView
        }

        return webView
    }

    func updateNSView(
        _ webView: SilentFunctionKeyWebView,
        context: Context
    ) {
        if context.coordinator.lastIsDark != isDark {
            context.coordinator.lastIsDark = isDark

            webView.wantsLayer = true
            webView.layer?.backgroundColor =
                isDark
                ? NSColor.black.cgColor
                : NSColor.white.cgColor

            webView.evaluateJavaScript(
                "typeof AnnotationManager !== 'undefined'"
                + " ? JSON.stringify("
                + "AnnotationManager.getFormState())"
                + " : null"
            ) { result, _ in
                let activeAnns = annotations.filter {
                    !$0.stale && (
                        $0.anchorData.type
                            == .lineRange
                        || $0.anchorData.type
                            == .diffRange
                    )
                }
                var initJS = buildAnnotationInitJS(
                    anchorType: "line_range",
                    blockSelector: ".code-line",
                    lineAttr: "data-line",
                    refPrefix: "Line",
                    itemLabel: itemLabel,
                    annotations: activeAnns,
                    htmlMap: annotationHTMLMap
                )
                if let stateJSON = result as? String {
                    initJS += "; AnnotationManager"
                        + ".restoreFormState("
                        + stateJSON + ")"
                }
                context.coordinator.pendingInitJS
                    = initJS

                let html = buildDiffHTML(
                    content: content,
                    isDark: isDark
                )
                webView.loadHTMLString(
                    html,
                    baseURL: URL(
                        string:
                            "galaxy://artifact-reader"
                    )
                )
            }
        }
    }

    func makeCoordinator() -> AnnotationCoordinator {
        AnnotationCoordinator(isDark: isDark)
    }
}

// MARK: - HTML Generation

/// Builds the full HTML document for a .gdiff artifact.
/// Parses the JSON, then emits one "file card" per
/// changed file with header + full-file rendering
/// overlaid with hunk add/delete shading.
private func buildDiffHTML(
    content: String,
    isDark: Bool
) -> String {
    // Parse the .gdiff JSON
    guard let data = content.data(using: .utf8),
          let doc = try? JSONDecoder().decode(
              GdiffDocument.self, from: data
          )
    else {
        return buildErrorHTML(
            "Failed to parse .gdiff content",
            isDark: isDark
        )
    }

    let hjsURL = Bundle.main.url(
        forResource: "highlight.min",
        withExtension: "js"
    )
    let hjsContent = hjsURL
        .flatMap { try? String(contentsOf: $0) } ?? ""

    let themeName =
        isDark ? "github-dark.min" : "github.min"
    let themeURL = Bundle.main.url(
        forResource: themeName,
        withExtension: "css"
    )
    let themeCSS = themeURL
        .flatMap { try? String(contentsOf: $0) } ?? ""

    let bgColor = isDark ? "#0d1117" : "#ffffff"
    let textColor = isDark ? "#e6edf3" : "#1f2328"
    let lineNumColor = isDark ? "#6e7681" : "#8b949e"
    let gutterBg = isDark ? "#010409" : "#f6f8fa"
    let borderColor = isDark ? "#30363d" : "#d0d7de"
    let headerBg = isDark ? "#161b22" : "#f6f8fa"
    let mutedFg = isDark ? "#8b949e" : "#656d76"

    // Diff color palette — GitHub-inspired.
    // Light-mode pairs line bg with a ~2× darker char
    // bg; dark-mode uses layered alpha for the same
    // effect. Number-gutter tints sit one notch darker
    // than the line body.
    let diffAddBg =
        isDark ? "rgba(46,160,67,0.15)" : "#e6ffec"
    let diffAddNum =
        isDark ? "rgba(46,160,67,0.30)" : "#ccffd8"
    let diffDelBg =
        isDark ? "rgba(248,81,73,0.15)" : "#ffebe9"
    let diffDelNum =
        isDark ? "rgba(248,81,73,0.30)" : "#ffd7d5"
    let charAddBg =
        isDark ? "rgba(46,160,67,0.55)" : "#abf2bc"
    let charDelBg =
        isDark ? "rgba(248,81,73,0.55)" : "#ffb4b1"
    // Status badge colors
    let yellowBg =
        isDark ? "rgba(255,200,0,0.18)" : "#fff8c5"
    let yellowFg = isDark ? "#f0d44a" : "#9a6700"
    let greenBg =
        isDark ? "rgba(46,160,67,0.20)" : "#dafbe1"
    let greenFg = isDark ? "#56d364" : "#116329"
    let redBg =
        isDark ? "rgba(248,81,73,0.20)" : "#ffebe9"
    let redFg = isDark ? "#f85149" : "#cf222e"
    let blueBg =
        isDark ? "rgba(88,166,255,0.18)" : "#ddf4ff"
    let blueFg = isDark ? "#79c0ff" : "#0969da"

    // Build file cards. Maintain a global `data-line`
    // counter so annotations map cleanly to document
    // lines across all file cards. Each card's header
    // consumes one data-line slot, enabling file-level
    // annotations "for free".
    var lineCounter = 0
    var cardsHTML = ""

    if doc.files.isEmpty {
        cardsHTML += buildEmptyStateHTML(
            summary: doc.metadata.summary
        )
    }

    for file in doc.files {
        lineCounter += 1
        let headerLine = lineCounter

        let result = renderFileCard(
            file: file,
            startingLine: lineCounter + 1,
            headerLine: headerLine
        )
        cardsHTML += result.html
        lineCounter = result.nextLine
    }

    // Summary header at top of document
    let metadataHTML =
        "<div class=\"diff-summary\">"
        + "<span class=\"diff-summary-branch\">"
        + htmlEscape(doc.metadata.branch)
        + "</span>"
        + "<span class=\"diff-summary-sep\">&middot;</span>"
        + "<span class=\"diff-summary-refs\">"
        + htmlEscape(doc.metadata.refFrom)
        + " → "
        + htmlEscape(doc.metadata.refTo)
        + "</span>"
        + "<span class=\"diff-summary-sep\">&middot;</span>"
        + "<span class=\"diff-summary-stats\">"
        + htmlEscape(doc.metadata.summary)
        + "</span>"
        + "</div>"

    let cssVars = annotationCSSVars(isDark: isDark)

    return """
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8">
    <meta name="viewport"
          content="width=device-width, initial-scale=1">
    <title>Galaxy Diff Reader</title>
    <style>
    :root {
        \(cssVars)
    }
    * { margin: 0; padding: 0; box-sizing: border-box; }
    html, body {
        background: \(bgColor);
        color: \(textColor);
        font-family: ui-monospace, 'SF Mono', Monaco,
            'Cascadia Code', 'Roboto Mono', Menlo,
            monospace;
        font-size: 13px;
        line-height: 1.45;
        -webkit-font-smoothing: antialiased;
    }
    body {
        padding: 12px;
    }
    .diff-summary {
        display: flex;
        align-items: center;
        gap: 10px;
        padding: 8px 12px;
        margin-bottom: 12px;
        background: \(headerBg);
        border: 1px solid \(borderColor);
        border-radius: 6px;
        font-family: -apple-system, system-ui,
            sans-serif;
        font-size: 12px;
        color: \(mutedFg);
        flex-wrap: wrap;
    }
    .diff-summary-branch {
        font-family: ui-monospace, monospace;
        font-weight: 600;
        color: \(textColor);
    }
    .diff-summary-refs {
        font-family: ui-monospace, monospace;
    }
    .diff-summary-sep {
        opacity: 0.5;
    }
    .empty-state {
        padding: 40px 20px;
        text-align: center;
        color: \(mutedFg);
        font-family: -apple-system, system-ui,
            sans-serif;
        font-size: 14px;
    }
    .file-card {
        margin-bottom: 16px;
        border: 1px solid \(borderColor);
        border-radius: 6px;
        overflow: hidden;
    }
    .file-header {
        display: flex;
        align-items: center;
        padding: 8px 12px;
        background: \(headerBg);
        border-bottom: 1px solid \(borderColor);
        font-family: -apple-system, system-ui,
            sans-serif;
        font-size: 13px;
        gap: 8px;
        flex-wrap: wrap;
    }
    .file-path {
        font-weight: 600;
        font-family: ui-monospace, monospace;
        word-break: break-all;
    }
    .file-old-path {
        font-family: ui-monospace, monospace;
        color: \(mutedFg);
        font-size: 12px;
        text-decoration: line-through;
    }
    .file-stats {
        margin-left: auto;
        font-size: 11px;
        color: \(mutedFg);
        font-family: ui-monospace, monospace;
    }
    .file-stats .stat-add { color: \(greenFg); }
    .file-stats .stat-del { color: \(redFg); }
    .status-badge {
        display: inline-block;
        padding: 1px 6px;
        border-radius: 3px;
        font-size: 11px;
        font-weight: 600;
    }
    .status-modified {
        background: \(yellowBg); color: \(yellowFg);
    }
    .status-added {
        background: \(greenBg); color: \(greenFg);
    }
    .status-deleted {
        background: \(redBg); color: \(redFg);
    }
    .status-renamed {
        background: \(blueBg); color: \(blueFg);
    }
    .status-binary {
        background: \(blueBg); color: \(blueFg);
    }
    .file-body {
        width: 100%;
        overflow-x: auto;
    }
    table.diff-table {
        border-collapse: collapse;
        width: max-content;
        min-width: 100%;
    }
    .code-line td {
        padding: 0;
        vertical-align: top;
        white-space: pre;
    }
    /* Three gutter columns: old line number, new line
       number, and a +/-/space marker. Shared column
       styling below; per-column widths follow. */
    .line-old-num, .line-new-num {
        text-align: right;
        padding-right: 10px !important;
        padding-left: 10px !important;
        color: \(lineNumColor);
        background: \(gutterBg);
        user-select: none;
        -webkit-user-select: none;
    }
    .line-old-num {
        width: 3.5em;
        min-width: 3.5em;
        max-width: 3.5em;
    }
    .line-new-num {
        width: 3.5em;
        min-width: 3.5em;
        max-width: 3.5em;
        border-right: 1px solid \(borderColor);
    }
    .line-marker {
        width: 1.25em;
        min-width: 1.25em;
        max-width: 1.25em;
        text-align: center;
        padding: 0 !important;
        user-select: none;
        -webkit-user-select: none;
        color: \(mutedFg);
    }
    .line-content {
        padding-left: 10px !important;
        padding-right: 16px !important;
    }
    /* Header lines — annotatable but styled as
       simple file-card headers, not code lines.
       Header uses a single colspan=4 cell. */
    .code-line.header-line td {
        padding: 0 !important;
    }
    /* Diff overlay — shade every column of add/del
       rows so the colored band spans the full row.
       `!important` is required because hljs adds the
       `.hljs` class to `.line-content` cells where it
       successfully highlights, and the `.hljs` rule
       (below) uses `!important transparent` to
       neutralize the theme's dark hljs background.
       Without `!important` here, hljs-highlighted
       cells (known languages like Swift) lose the
       diff row shading while unknown languages
       (Crystal, etc.) keep it — an inconsistency
       with no user-facing logic. */
    .diff-add td {
        background-color: \(diffAddBg) !important;
    }
    .diff-add td.line-old-num,
    .diff-add td.line-new-num {
        background-color: \(diffAddNum) !important;
    }
    .diff-add td.line-marker {
        color: \(greenFg);
        font-weight: 600;
    }
    .diff-del td {
        background-color: \(diffDelBg) !important;
    }
    .diff-del td.line-old-num,
    .diff-del td.line-new-num {
        background-color: \(diffDelNum) !important;
    }
    .diff-del td.line-marker {
        color: \(redFg);
        font-weight: 600;
    }
    .char-add {
        background-color: \(charAddBg);
        border-radius: 2px;
    }
    .char-del {
        background-color: \(charDelBg);
        border-radius: 2px;
    }
    .binary-notice {
        padding: 16px;
        text-align: center;
        color: \(mutedFg);
        font-family: -apple-system, system-ui,
            sans-serif;
        font-style: italic;
    }
    /* hljs background suppression */
    .hljs { background: transparent !important; }
    /* Annotation highlight adaption for table rows */
    .code-line.annotation-highlight td {
        background-color: rgba(88, 166, 255, 0.12);
    }
    .code-line.annotation-highlight td:first-child {
        border-left: 3px solid
            rgba(88, 166, 255, 0.6);
        padding-left: 7px !important;
    }
    .code-line.annotation-expanded-highlight td {
        background-color:
            var(--annotation-active-block-bg);
    }
    .code-line.annotation-expanded-highlight
        td:first-child {
        border-left: 3px solid
            var(--annotation-active-block-border);
        padding-left: 7px !important;
    }
    \(annotationCSS)
    \(themeCSS)
    </style>
    </head>
    <body>
    \(metadataHTML)
    \(cardsHTML)
    <script>\(hjsContent)</script>
    <script>
    if (typeof hljs !== 'undefined') {
        document.querySelectorAll(
            '.diff-table tbody[data-lang]'
        ).forEach(function(tbody) {
            var lang = tbody.getAttribute('data-lang');
            tbody.querySelectorAll('.line-content')
                .forEach(function(el) {
                    // Skip hljs for lines that already
                    // have char-level spans, and for
                    // header rows
                    if (el.querySelector('.char-add')
                        || el.querySelector('.char-del')
                        || el.closest('.header-line')) {
                        return;
                    }
                    if (lang && lang !== 'plaintext') {
                        el.classList.add(
                            'language-' + lang
                        );
                    }
                    hljs.highlightElement(el);
                });
        });
    }
    </script>
    <script>
    \(annotationManagerJS)
    </script>
    <script>\(emojiDataJS)</script>
    <script>\(emojiAutocompleteJS)</script>
    </body>
    </html>
    """
}

// MARK: - File Card Rendering

private struct FileCardResult {
    let html: String
    let nextLine: Int
}

/// Render a single file card: header + body.
/// Returns the assembled HTML plus the next
/// available global line number.
private func renderFileCard(
    file: GdiffFile,
    startingLine: Int,
    headerLine: Int
) -> FileCardResult {
    let (statusClass, statusLabel) = statusBadge(
        for: file.status
    )
    let (adds, dels) = countChanges(in: file.hunks)
    let lang = file.language ?? "plaintext"

    // Header row — annotatable, maps to headerLine
    var html = "<div class=\"file-card\">"
    html +=
        "<table class=\"diff-table\">"
        + "<tbody data-lang=\"\(lang)\">"
    // Every row within this file card carries its
    // path + status so the JS annotation manager can
    // capture a structured anchor when the user saves
    // an annotation — see `diff_range` in
    // ArtifactsView.handleAnnotationMessage.
    let fp = htmlEscape(file.path)
    let fs = htmlEscape(file.status)
    let fileAttrs =
        " data-file-path=\"\(fp)\""
        + " data-file-status=\"\(fs)\""

    html +=
        "<tr class=\"code-line header-line\""
        + " data-line=\"\(headerLine)\""
        + fileAttrs
        + " data-kind=\"file-header\">"
        + "<td colspan=\"4\" class=\"line-content\">"
        + "<div class=\"file-header\">"
    if file.status == "renamed",
       let oldPath = file.oldPath,
       !oldPath.isEmpty
    {
        html +=
            "<span class=\"file-old-path\">"
            + htmlEscape(oldPath) + "</span>"
            + " <span class=\"file-path\">→ "
            + htmlEscape(file.path) + "</span>"
    } else {
        html +=
            "<span class=\"file-path\">"
            + htmlEscape(file.path) + "</span>"
    }
    html +=
        "<span class=\"status-badge "
        + statusClass + "\">"
        + statusLabel + "</span>"
    html +=
        "<span class=\"file-stats\">"
        + "<span class=\"stat-add\">+\(adds)</span>"
        + " <span class=\"stat-del\">-\(dels)</span>"
        + "</span>"
    html += "</div></td></tr>"

    // Body — file content with diff overlay
    let bodyResult = renderFileBody(
        file: file,
        startingLine: startingLine,
        fileAttrs: fileAttrs
    )
    html += bodyResult.html
    html += "</tbody></table></div>"

    return FileCardResult(
        html: html,
        nextLine: bodyResult.nextLine
    )
}

/// Render a file's body rows. For modified/added
/// files, renders the "after" content; for deleted
/// files, the "before" content. Hunk data drives
/// which lines get shaded green/red, and adjacent
/// delete/add pairs get character-level highlighting.
private func renderFileBody(
    file: GdiffFile,
    startingLine: Int,
    fileAttrs: String
) -> FileCardResult {
    // Binary or otherwise missing content
    let isBinary =
        file.before == nil && file.after == nil
    if isBinary {
        let line = startingLine
        let html =
            "<tr class=\"code-line\""
            + " data-line=\"\(line)\""
            + fileAttrs
            + " data-kind=\"binary\">"
            + "<td colspan=\"4\" class=\"line-content\">"
            + "<div class=\"binary-notice\">"
            + "Binary file — contents not shown"
            + "</div></td></tr>"
        return FileCardResult(
            html: html,
            nextLine: line
        )
    }

    // Deleted file — show "before" content
    // with every line marked as delete.
    if file.status == "deleted" {
        let source = file.before ?? ""
        return renderAllLinesAs(
            source: source,
            kind: .delete,
            startingLine: startingLine,
            fileAttrs: fileAttrs
        )
    }

    // Added file — show "after" content with
    // every line marked as add.
    if file.status == "added" {
        let source = file.after ?? ""
        return renderAllLinesAs(
            source: source,
            kind: .add,
            startingLine: startingLine,
            fileAttrs: fileAttrs
        )
    }

    // Modified / renamed file — render "after"
    // content with hunk overlay.
    let source = file.after ?? ""
    return renderWithHunkOverlay(
        source: source,
        hunks: file.hunks,
        startingLine: startingLine,
        fileAttrs: fileAttrs
    )
}

/// Whole-file render mode for pure-add and pure-delete
/// files. `.add` numbers the "after" side, `.delete`
/// the "before" side.
private enum WholeFileKind {
    case add
    case delete
}

/// Renders every line of `source` as an add or delete,
/// populating just the relevant gutter column. Used
/// for pure-add (newly-created) and pure-delete files
/// where no hunk overlay is needed.
private func renderAllLinesAs(
    source: String,
    kind: WholeFileKind,
    startingLine: Int,
    fileAttrs: String
) -> FileCardResult {
    let lines = splitLines(source)
    var html = ""
    var lineNo = startingLine
    for (i, line) in lines.enumerated() {
        let displayLine = i + 1
        switch kind {
        case .add:
            html += renderAddRow(
                newNo: displayLine,
                dataLine: lineNo,
                content: line,
                highlighted: nil,
                fileAttrs: fileAttrs
            )
        case .delete:
            html += renderDeleteRow(
                oldNo: displayLine,
                dataLine: lineNo,
                content: line,
                highlighted: nil,
                fileAttrs: fileAttrs
            )
        }
        lineNo += 1
    }
    return FileCardResult(
        html: html,
        nextLine: lineNo - 1
    )
}

/// Renders `source` ("after" file content) with
/// hunk overlay:
/// - Context (non-hunk) lines render normally
/// - Lines in `add` positions shade green
/// - `delete` lines are inserted at their
///   recorded positions and shade red
/// - Adjacent delete+add pairs get char-level
///   highlighting
private func renderWithHunkOverlay(
    source: String,
    hunks: [GdiffHunk],
    startingLine: Int,
    fileAttrs: String
) -> FileCardResult {
    // We walk the "after" file top-to-bottom, emitting
    // untouched regions as context rows and splicing
    // hunk lines in at their recorded positions.
    // cursorBefore / cursorAfter track the next old /
    // new line numbers to render.
    let afterLines = splitLines(source)
    var html = ""
    var lineNo = startingLine

    let sortedHunks = hunks.sorted {
        $0.newStart < $1.newStart
    }

    var cursorBefore = 1
    var cursorAfter = 1
    for hunk in sortedHunks {
        // Emit untouched "after" lines up to the
        // hunk's start. In untouched regions the
        // before/after cursors advance in lockstep.
        while cursorAfter < hunk.newStart,
              cursorAfter <= afterLines.count
        {
            let text = afterLines[cursorAfter - 1]
            html += renderContextRow(
                oldNo: cursorBefore,
                newNo: cursorAfter,
                dataLine: lineNo,
                content: text,
                fileAttrs: fileAttrs
            )
            cursorBefore += 1
            cursorAfter += 1
            lineNo += 1
        }

        // Re-sync cursors to the hunk's declared
        // start positions in case of drift.
        cursorBefore = hunk.oldStart
        cursorAfter = hunk.newStart

        // Render hunk lines with char-level
        // highlighting for adjacent del/add pairs.
        let pairedLines = pairDeleteAddLines(
            hunk.lines
        )

        for entry in pairedLines {
            switch entry {
            case .context(let gline):
                let oldN = gline.oldNo
                let newN = gline.newNo
                if let n = oldN { cursorBefore = n + 1 }
                if let n = newN { cursorAfter = n + 1 }
                html += renderContextRow(
                    oldNo: oldN,
                    newNo: newN,
                    dataLine: lineNo,
                    content: gline.content,
                    fileAttrs: fileAttrs
                )
                lineNo += 1
            case .delete(let gline):
                if let n = gline.oldNo {
                    cursorBefore = n + 1
                }
                html += renderDeleteRow(
                    oldNo: gline.oldNo,
                    dataLine: lineNo,
                    content: gline.content,
                    highlighted: nil,
                    fileAttrs: fileAttrs
                )
                lineNo += 1
            case .add(let gline):
                if let n = gline.newNo {
                    cursorAfter = n + 1
                }
                html += renderAddRow(
                    newNo: gline.newNo,
                    dataLine: lineNo,
                    content: gline.content,
                    highlighted: nil,
                    fileAttrs: fileAttrs
                )
                lineNo += 1
            case .pair(let del, let add):
                let (delHL, addHL) =
                    characterLevelDiff(
                        delLine: del.content,
                        addLine: add.content
                    )
                if let n = del.oldNo {
                    cursorBefore = n + 1
                }
                html += renderDeleteRow(
                    oldNo: del.oldNo,
                    dataLine: lineNo,
                    content: del.content,
                    highlighted: delHL,
                    fileAttrs: fileAttrs
                )
                lineNo += 1
                if let n = add.newNo {
                    cursorAfter = n + 1
                }
                html += renderAddRow(
                    newNo: add.newNo,
                    dataLine: lineNo,
                    content: add.content,
                    highlighted: addHL,
                    fileAttrs: fileAttrs
                )
                lineNo += 1
            }
        }
    }

    // Emit any trailing untouched "after" lines —
    // before/after advance in lockstep again.
    while cursorAfter <= afterLines.count {
        let text = afterLines[cursorAfter - 1]
        html += renderContextRow(
            oldNo: cursorBefore,
            newNo: cursorAfter,
            dataLine: lineNo,
            content: text,
            fileAttrs: fileAttrs
        )
        cursorBefore += 1
        cursorAfter += 1
        lineNo += 1
    }

    return FileCardResult(
        html: html,
        nextLine: lineNo - 1
    )
}

// MARK: - Row Rendering Helpers

/// Build a 4-cell diff row: old-num, new-num, marker,
/// content. `oldNo` / `newNo` may be nil to render an
/// empty gutter cell (e.g. adds have no old number,
/// deletes have no new number). `marker` is one of
/// `" "`, `"+"`, or `"-"`.
///
/// `fileAttrs` is a pre-rendered attribute string
/// (`data-file-path`/`data-file-status`) carried down
/// from the enclosing file card. `kind` tags the row
/// as `context`/`add`/`delete` so JS can collect
/// structured anchor data at annotation-create time.
private func renderRow(
    oldNo: Int?,
    newNo: Int?,
    marker: String,
    rowClass: String,
    dataLine: Int,
    body: String,
    fileAttrs: String,
    kind: String
) -> String {
    let oldCell = oldNo.map(String.init) ?? ""
    let newCell = newNo.map(String.init) ?? ""
    let markerCell = marker == " " ? "" : marker
    let content = body.isEmpty ? " " : body

    let oldAttr = oldNo.map {
        " data-old-line=\"\($0)\""
    } ?? ""
    let newAttr = newNo.map {
        " data-new-line=\"\($0)\""
    } ?? ""

    return
        "<tr class=\"code-line\(rowClass)\""
        + " data-line=\"\(dataLine)\""
        + fileAttrs
        + " data-kind=\"\(kind)\""
        + oldAttr + newAttr + ">"
        + "<td class=\"line-old-num\">\(oldCell)</td>"
        + "<td class=\"line-new-num\">\(newCell)</td>"
        + "<td class=\"line-marker\">\(markerCell)</td>"
        + "<td class=\"line-content\">\(content)</td>"
        + "</tr>"
}

private func renderContextRow(
    oldNo: Int?,
    newNo: Int?,
    dataLine: Int,
    content: String,
    fileAttrs: String
) -> String {
    renderRow(
        oldNo: oldNo,
        newNo: newNo,
        marker: " ",
        rowClass: "",
        dataLine: dataLine,
        body: htmlEscape(content),
        fileAttrs: fileAttrs,
        kind: "context"
    )
}

private func renderAddRow(
    newNo: Int?,
    dataLine: Int,
    content: String,
    highlighted: String?,
    fileAttrs: String
) -> String {
    renderRow(
        oldNo: nil,
        newNo: newNo,
        marker: "+",
        rowClass: " diff-add",
        dataLine: dataLine,
        body: highlighted ?? htmlEscape(content),
        fileAttrs: fileAttrs,
        kind: "add"
    )
}

private func renderDeleteRow(
    oldNo: Int?,
    dataLine: Int,
    content: String,
    highlighted: String?,
    fileAttrs: String
) -> String {
    renderRow(
        oldNo: oldNo,
        newNo: nil,
        marker: "-",
        rowClass: " diff-del",
        dataLine: dataLine,
        body: highlighted ?? htmlEscape(content),
        fileAttrs: fileAttrs,
        kind: "delete"
    )
}

// MARK: - Hunk Line Pairing

/// Entries emitted when walking a hunk's lines.
/// `.pair` means a delete immediately followed by
/// an add (same block) — eligible for char-level
/// highlighting.
private enum HunkEntry {
    case context(GdiffLine)
    case add(GdiffLine)
    case delete(GdiffLine)
    case pair(GdiffLine, GdiffLine)
}

/// Walks a hunk's lines and pairs contiguous runs
/// of deletes with contiguous runs of adds so we
/// can character-diff them. When the run sizes
/// don't match, we pair what we can 1:1 and leave
/// leftovers as standalone add/delete rows.
private func pairDeleteAddLines(
    _ lines: [GdiffLine]
) -> [HunkEntry] {
    var result: [HunkEntry] = []
    var i = 0
    while i < lines.count {
        let line = lines[i]
        if line.type == "delete" {
            // Collect contiguous deletes
            var dels: [GdiffLine] = []
            while i < lines.count,
                  lines[i].type == "delete"
            {
                dels.append(lines[i])
                i += 1
            }
            // Collect immediately-following adds
            var adds: [GdiffLine] = []
            while i < lines.count,
                  lines[i].type == "add"
            {
                adds.append(lines[i])
                i += 1
            }
            // Pair up
            let pairCount = min(dels.count, adds.count)
            for p in 0..<pairCount {
                result.append(
                    .pair(dels[p], adds[p])
                )
            }
            // Leftover deletes (more deletes than adds)
            if dels.count > pairCount {
                for d in pairCount..<dels.count {
                    result.append(.delete(dels[d]))
                }
            }
            // Leftover adds (more adds than deletes)
            if adds.count > pairCount {
                for a in pairCount..<adds.count {
                    result.append(.add(adds[a]))
                }
            }
        } else if line.type == "add" {
            result.append(.add(line))
            i += 1
        } else {
            result.append(.context(line))
            i += 1
        }
    }
    return result
}

// MARK: - Character-Level Diff

/// Computes character-level highlights for a
/// delete/add line pair using a simple LCS-based
/// character diff. Returns (delHTML, addHTML) with
/// <span class="char-del"> / <span class="char-add">
/// wrapping changed runs. Falls back to `nil, nil`
/// if the diff is degenerate (identical or wholly
/// different).
private func characterLevelDiff(
    delLine: String,
    addLine: String
) -> (String?, String?) {
    // Skip if either side is empty or if they're
    // identical — full-line highlighting already
    // conveys the change.
    if delLine.isEmpty || addLine.isEmpty {
        return (nil, nil)
    }
    if delLine == addLine {
        return (nil, nil)
    }

    // Very long lines: skip char-diff to avoid
    // quadratic-time blowup. The full-line shading
    // still shows the change.
    if delLine.count > 500
        || addLine.count > 500
    {
        return (nil, nil)
    }

    let delChars = Array(delLine)
    let addChars = Array(addLine)

    // Compute LCS-based diff ops. Classic O(N*M)
    // table — fine for lines up to ~500 chars.
    let ops = lcsDiff(delChars, addChars)

    var delHTML = ""
    var addHTML = ""
    var delSpanOpen = false
    var addSpanOpen = false

    for op in ops {
        switch op {
        case .equal(let ch):
            if delSpanOpen {
                delHTML += "</span>"
                delSpanOpen = false
            }
            if addSpanOpen {
                addHTML += "</span>"
                addSpanOpen = false
            }
            let escaped = htmlEscape(String(ch))
            delHTML += escaped
            addHTML += escaped
        case .delete(let ch):
            if !delSpanOpen {
                delHTML += "<span class=\"char-del\">"
                delSpanOpen = true
            }
            delHTML += htmlEscape(String(ch))
        case .insert(let ch):
            if !addSpanOpen {
                addHTML += "<span class=\"char-add\">"
                addSpanOpen = true
            }
            addHTML += htmlEscape(String(ch))
        }
    }
    if delSpanOpen { delHTML += "</span>" }
    if addSpanOpen { addHTML += "</span>" }

    return (delHTML, addHTML)
}

private enum DiffOp {
    case equal(Character)
    case delete(Character)
    case insert(Character)
}

/// Classic dynamic-programming LCS followed by a
/// backtrace to produce a delete/insert/equal op
/// stream.
private func lcsDiff(
    _ a: [Character],
    _ b: [Character]
) -> [DiffOp] {
    let n = a.count
    let m = b.count
    if n == 0 {
        return b.map { .insert($0) }
    }
    if m == 0 {
        return a.map { .delete($0) }
    }

    // LCS length table
    var dp = Array(
        repeating: Array(repeating: 0, count: m + 1),
        count: n + 1
    )
    for i in 1...n {
        for j in 1...m {
            if a[i - 1] == b[j - 1] {
                dp[i][j] = dp[i - 1][j - 1] + 1
            } else {
                dp[i][j] = max(
                    dp[i - 1][j], dp[i][j - 1]
                )
            }
        }
    }

    // Backtrace
    var ops: [DiffOp] = []
    var i = n
    var j = m
    while i > 0 && j > 0 {
        if a[i - 1] == b[j - 1] {
            ops.append(.equal(a[i - 1]))
            i -= 1
            j -= 1
        } else if dp[i - 1][j] >= dp[i][j - 1] {
            ops.append(.delete(a[i - 1]))
            i -= 1
        } else {
            ops.append(.insert(b[j - 1]))
            j -= 1
        }
    }
    while i > 0 {
        ops.append(.delete(a[i - 1]))
        i -= 1
    }
    while j > 0 {
        ops.append(.insert(b[j - 1]))
        j -= 1
    }
    return ops.reversed()
}

// MARK: - Utility

private func statusBadge(
    for status: String
) -> (String, String) {
    switch status {
    case "added":
        return ("status-added", "added")
    case "deleted":
        return ("status-deleted", "deleted")
    case "renamed":
        return ("status-renamed", "renamed")
    case "binary":
        return ("status-binary", "binary")
    default:
        return ("status-modified", "modified")
    }
}

private func countChanges(
    in hunks: [GdiffHunk]
) -> (Int, Int) {
    var adds = 0
    var dels = 0
    for h in hunks {
        for l in h.lines {
            if l.type == "add" { adds += 1 }
            if l.type == "delete" { dels += 1 }
        }
    }
    return (adds, dels)
}

/// Split a string on newlines. Unlike
/// `components(separatedBy:)`, we keep trailing
/// empty lines if the content ends with a newline.
private func splitLines(_ s: String) -> [String] {
    if s.isEmpty { return [] }
    var lines = s.components(separatedBy: "\n")
    // Drop trailing empty element if the source
    // ended with "\n" — it's a Unix convention,
    // not a real empty line to render.
    if let last = lines.last, last.isEmpty,
       s.hasSuffix("\n")
    {
        lines.removeLast()
    }
    return lines
}

private func htmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(
            of: "\"", with: "&quot;"
        )
        .replacingOccurrences(
            of: "'", with: "&#39;"
        )
}

// MARK: - Empty / Error States

private func buildEmptyStateHTML(
    summary: String
) -> String {
    "<div class=\"empty-state\">"
        + "No files changed in this diff."
        + "<br><br>"
        + "<small>"
        + htmlEscape(summary)
        + "</small>"
        + "</div>"
}

private func buildErrorHTML(
    _ message: String,
    isDark: Bool
) -> String {
    let bgColor = isDark ? "#0d1117" : "#ffffff"
    let textColor = isDark ? "#e6edf3" : "#1f2328"
    let mutedFg = isDark ? "#8b949e" : "#656d76"
    return """
    <!DOCTYPE html>
    <html><head><meta charset="utf-8"><style>
    body {
        background: \(bgColor);
        color: \(textColor);
        font-family: -apple-system, system-ui, sans-serif;
        padding: 40px 20px;
        text-align: center;
    }
    .error-title { font-size: 16px; margin-bottom: 8px; }
    .error-detail { color: \(mutedFg); font-size: 13px; }
    </style></head><body>
    <div class="error-title">
      Unable to render diff
    </div>
    <div class="error-detail">\(htmlEscape(message))</div>
    </body></html>
    """
}
