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
    // Subtle lift on the collapse-toggle button hover;
    // semi-transparent mid-gray reads against both the
    // light and dark header backgrounds without needing
    // theme-specific tuning beyond the alpha.
    let hoverBg = isDark
        ? "rgba(177,186,196,0.12)"
        : "rgba(208,215,222,0.32)"
    // GitHub-style tooltip pill — both themes use a dark
    // pill so it stands out against either card header.
    // Dark theme uses a slightly lighter bg so the pill
    // reads against the near-black card, not into it.
    let tooltipBg = isDark ? "#272c33" : "#24292f"
    let tooltipFg = isDark ? "#f0f6fc" : "#ffffff"

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
    //
    // Note: collapsed gaps (see `renderWithHunkOverlay`)
    // still *reserve* data-line slots for the hidden
    // rows, so when the user expands a gap the newly
    // inserted rows get predictable, non-colliding IDs.
    var lineCounter = 0
    var cardsHTML = ""

    if doc.files.isEmpty {
        cardsHTML += buildEmptyStateHTML(
            summary: doc.metadata.summary
        )
    }

    for (fileIndex, file) in doc.files.enumerated() {
        lineCounter += 1
        let headerLine = lineCounter

        let result = renderFileCard(
            file: file,
            fileIndex: fileIndex,
            startingLine: lineCounter + 1,
            headerLine: headerLine
        )
        cardsHTML += result.html
        lineCounter = result.nextLine
    }

    // Serialize per-file "after" line arrays for
    // client-side gap expansion. JS reads from
    // `window.GALAXY_AFTERLINES[fileIndex]` when a user
    // clicks an unchanged-region expand affordance.
    let afterLinesJS = buildAfterLinesJS(files: doc.files)

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
        /* `overflow-wrap: break-word` lets long
           paths break mid-path only when they would
           actually overflow, without making the
           element's min-content 1 character the way
           `word-break: break-all` does — which was
           collapsing the file-header flex container
           on some cards. */
        overflow-wrap: break-word;
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
    }
    /* File-card collapse toggle — GitHub-style
       chevron button that toggles the card body.
       Positioned as the first child of .file-header;
       the parent's `gap: 8px` handles spacing to the
       file path. `line-height: 0` prevents the SVG
       from contributing extra vertical whitespace. */
    .file-collapse-toggle {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        width: 20px;
        height: 20px;
        border: none;
        background: transparent;
        color: \(mutedFg);
        cursor: pointer;
        padding: 0;
        border-radius: 4px;
        flex-shrink: 0;
        line-height: 0;
        font: inherit;
    }
    .file-collapse-toggle:hover,
    .file-collapse-toggle:focus-visible {
        background: \(hoverBg);
        color: \(textColor);
        outline: none;
    }
    .file-collapse-toggle .chevron {
        transition: transform 0.12s ease-in-out;
    }
    /* Rotate chevron-down → chevron-right when the
       card is collapsed. (-90deg rotates the tip from
       the 6 o'clock position to 3 o'clock.) */
    .file-card.collapsed
        .file-collapse-toggle .chevron {
        transform: rotate(-90deg);
    }
    /* GitHub-style tooltip pill. Rendered as a single
       element appended to <body> (not a pseudo-element
       on the button) so it escapes the file-card's
       `overflow: hidden` — which would otherwise clip
       it on the left edge for cards whose toggle sits
       at the start, and clip it entirely below
       collapsed cards (no body room beneath). JS
       positions it via getBoundingClientRect on hover. */
    .file-tooltip {
        position: fixed;
        top: 0;
        left: 0;
        background: \(tooltipBg);
        color: \(tooltipFg);
        padding: 4px 8px;
        border-radius: 6px;
        font-size: 11px;
        font-family: -apple-system, system-ui,
            sans-serif;
        font-weight: 500;
        white-space: nowrap;
        pointer-events: none;
        opacity: 0;
        transition: opacity 0.1s ease-in-out;
        z-index: 1000;
    }
    .file-tooltip.visible { opacity: 1; }
    /* Collapse the card body — hides code-line rows
       and gap-spacer rows in one selector. Gap-expand
       DOM state is preserved under display:none, so
       re-expanding the card restores any previously
       revealed lines. */
    .file-card.collapsed tbody > tr:not(.header-line) {
        display: none;
    }
    /* Drop the header's bottom border when collapsed
       so the card reads as a single compact bar. */
    .file-card.collapsed .file-header {
        border-bottom: none;
    }
    /* Annotation cards live on document.body (outside
       any file-card, so they escape the card's
       overflow clip). When their file is collapsed,
       they need to be hidden explicitly — the in-tbody
       spacer row is already handled by the collapse
       selector above, but the floating card isn't. */
    .annotation-card.file-hidden {
        display: none !important;
    }
    /* Auto table layout — the browser sizes each
       column from content. `width: 100%` constrains
       the overall table to the card; `pre-wrap`
       below lets cells wrap at word boundaries when
       their content exceeds the remaining width. No
       `table-layout: fixed` — it breaks cells that
       don't get the `.hljs` class (crystal, etc.)
       whose intrinsic-content column sizing differs
       from cells that do. */
    table.diff-table {
        border-collapse: collapse;
        width: 100%;
        tab-size: 4;
        -moz-tab-size: 4;
    }
    .code-line td {
        padding: 0;
        vertical-align: top;
        /* `pre-wrap` preserves leading whitespace /
           indentation while allowing wrapping at
           word boundaries. */
        white-space: pre-wrap;
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
        width: 5em;
        min-width: 5em;
        max-width: 5em;
    }
    .line-new-num {
        width: 5em;
        min-width: 5em;
        max-width: 5em;
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
    /* Unchanged-region collapse — spacer row replacing
       long runs of context lines between hunks. Three
       affordances: expand-up (reveals N lines at the
       top), expand-all (reveals the whole gap), and
       expand-down (reveals N lines at the bottom). */
    .unchanged-gap td.gap-spacer {
        padding: 4px 12px !important;
        background: \(gutterBg) !important;
        border-top: 1px solid \(borderColor);
        border-bottom: 1px solid \(borderColor);
        font-family: -apple-system, system-ui,
            sans-serif;
        font-size: 11px;
        color: \(mutedFg);
        white-space: normal;
    }
    .gap-spacer-inner {
        display: flex;
        align-items: stretch;
        gap: 12px;
        width: 100%;
    }
    /* Arrow column — vertical stack for `gap-stacked`
       (two buttons, taller row); single button for
       `gap-combined` (shorter row). Row height is
       driven by this column's content. */
    .gap-expand-group {
        display: flex;
        flex-direction: column;
        gap: 2px;
        flex: 0 0 auto;
    }
    .gap-expand {
        background: transparent;
        border: 0;
        padding: 3px 10px;
        margin: 0;
        color: \(mutedFg);
        font-family: inherit;
        font-size: 11px;
        cursor: pointer;
        border-radius: 4px;
        display: inline-flex;
        align-items: center;
        gap: 4px;
        line-height: 1.4;
        white-space: nowrap;
    }
    .gap-expand:hover {
        background: rgba(127, 127, 127, 0.14);
        color: \(textColor);
    }
    /* Center the "show all" button in whatever space
       remains after the arrow column. Sized to its
       text, not flex-stretched. */
    .gap-all-wrap {
        flex: 1 1 auto;
        display: flex;
        align-items: center;
        justify-content: center;
    }
    .gap-expand-all {
        flex: 0 0 auto;
        font-style: italic;
    }
    .gap-arrow {
        font-weight: 700;
        font-size: 13px;
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
    <script>\(afterLinesJS)</script>
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
    \(gapExpansionJS)
    </script>
    <script>
    \(fileCollapseJS)
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
/// available global line number. `fileIndex` is
/// the position of this file in
/// `GdiffDocument.files`; it's embedded in gap
/// spacer rows so JS can look up the file's
/// `after` contents on expansion.
private func renderFileCard(
    file: GdiffFile,
    fileIndex: Int,
    startingLine: Int,
    headerLine: Int
) -> FileCardResult {
    let (statusClass, statusLabel) = statusBadge(
        for: file.status
    )
    let (adds, dels) = countChanges(in: file.hunks)
    let lang = file.language ?? "plaintext"

    // Header row — annotatable, maps to headerLine
    let fp = htmlEscape(file.path)
    let fs = htmlEscape(file.status)
    // File-card carries its own `data-file-path` so
    // the collapse handler can match annotation cards
    // (also stamped with `data-file-path`) and hide
    // them together with the body rows.
    var html =
        "<div class=\"file-card\""
        + " data-file-path=\"\(fp)\">"
    html +=
        "<table class=\"diff-table\">"
        + "<tbody data-lang=\"\(lang)\">"
    // Every row within this file card carries its
    // path + status so the JS annotation manager can
    // capture a structured anchor when the user saves
    // an annotation — see `diff_range` in
    // ArtifactsView.handleAnnotationMessage.
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
        + "<button type=\"button\""
        + " class=\"file-collapse-toggle\""
        + " data-tooltip=\"Collapse file\""
        + " aria-label=\"Collapse file\""
        + " aria-expanded=\"true\">"
        + "<svg class=\"chevron\" width=\"12\""
        + " height=\"12\" viewBox=\"0 0 16 16\""
        + " aria-hidden=\"true\">"
        + "<path fill=\"currentColor\""
        + " d=\"M12.78 5.22a.749.749 0 0 1 0"
        + " 1.06l-4.25 4.25a.749.749 0 0 1-1.06"
        + " 0L3.22 6.28a.749.749 0 1 1 1.06-1.06L8"
        + " 8.939l3.72-3.719a.749.749 0 0 1 1.06"
        + " 0Z\"/>"
        + "</svg>"
        + "</button>"
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
        fileIndex: fileIndex,
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
///
/// `fileIndex` is the file's position in the parent
/// document; used by modified-file rendering to tag
/// gap spacer rows so JS can resolve `after` content
/// on expansion.
private func renderFileBody(
    file: GdiffFile,
    fileIndex: Int,
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
        fileIndex: fileIndex,
        language: file.language ?? "plaintext",
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
/// - Long runs of untouched lines between hunks
///   collapse to a spacer with expand affordances;
///   see `emitGapRegion`.
private func renderWithHunkOverlay(
    source: String,
    hunks: [GdiffHunk],
    fileIndex: Int,
    language: String,
    startingLine: Int,
    fileAttrs: String
) -> FileCardResult {
    // We walk the "after" file top-to-bottom, emitting
    // untouched regions as context rows (or a collapsed
    // spacer for long regions) and splicing hunk lines
    // in at their recorded positions. cursorBefore /
    // cursorAfter track the next old / new line numbers
    // to render.
    let afterLines = splitLines(source)
    var html = ""
    var lineNo = startingLine
    var gapCounter = 0

    let sortedHunks = hunks.sorted {
        $0.newStart < $1.newStart
    }

    var cursorBefore = 1
    var cursorAfter = 1
    for (hunkIndex, hunk) in sortedHunks.enumerated() {
        // Emit the gap of untouched "after" lines up
        // to the hunk's start. Short gaps render in
        // full; long gaps collapse to a spacer row.
        // The first hunk's pre-gap is the SOF gap
        // (if non-empty); subsequent pre-gaps are
        // middle gaps.
        let position: GapPosition =
            hunkIndex == 0 ? .sof : .middle
        let gapResult = emitGapRegion(
            afterLines: afterLines,
            cursorBefore: cursorBefore,
            cursorAfter: cursorAfter,
            gapEnd: hunk.newStart - 1,
            fileIndex: fileIndex,
            gapIndex: gapCounter,
            position: position,
            language: language,
            startingLineNo: lineNo,
            fileAttrs: fileAttrs
        )
        html += gapResult.html
        lineNo = gapResult.nextLineNo
        cursorBefore = gapResult.nextCursorBefore
        cursorAfter = gapResult.nextCursorAfter
        gapCounter += 1

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

    // Emit any trailing untouched "after" lines.
    // Short tails render in full; long tails collapse
    // to a spacer with the `.eof` position variant
    // (one button `↓ Show lines below`).
    let tailResult = emitGapRegion(
        afterLines: afterLines,
        cursorBefore: cursorBefore,
        cursorAfter: cursorAfter,
        gapEnd: afterLines.count,
        fileIndex: fileIndex,
        gapIndex: gapCounter,
        position: .eof,
        language: language,
        startingLineNo: lineNo,
        fileAttrs: fileAttrs
    )
    html += tailResult.html
    lineNo = tailResult.nextLineNo

    return FileCardResult(
        html: html,
        nextLine: lineNo - 1
    )
}

// MARK: - Unchanged-Region Collapsing

/// Gaps with at most this many lines render in full —
/// below this size, showing a spacer costs more visual
/// noise than the scroll it saves.
private let gapCollapseThreshold = 10

/// Each expand-up / expand-down click reveals this many
/// lines. Also serves as the stacked-vs-combined
/// threshold: gaps larger than this render stacked (two
/// directional buttons), gaps at or below render a
/// single combined/directional button that reveals all.
/// Kept in sync with `GAP_EXPAND_STEP` in the inline JS.
private let gapExpandStep = 30

/// Position of a gap within a file's body. Drives which
/// button variants the spacer emits:
/// - `.sof` (before the first hunk) — one button, `↑
///   Show lines above`, reveals bottom-of-gap (the
///   lines just before the first hunk).
/// - `.middle` (between two hunks) — two buttons in
///   stacked mode, one combined button in small mode.
/// - `.eof` (after the last hunk) — one button, `↓
///   Show lines below`, reveals top-of-gap (the lines
///   just after the last hunk).
///
/// The arrow/label inversion (top button = `↓ below`,
/// bottom button = `↑ above`) follows the reference-line
/// semantic: each button's label describes where the
/// revealed lines sit relative to the adjacent visible
/// hunk, not relative to the spacer itself.
private enum GapPosition {
    case sof
    case middle
    case eof

    var htmlValue: String {
        switch self {
        case .sof: return "sof"
        case .middle: return "middle"
        case .eof: return "eof"
        }
    }

    var rowClass: String {
        switch self {
        case .sof: return "gap-sof"
        case .middle: return "gap-middle"
        case .eof: return "gap-eof"
        }
    }
}

private struct GapEmissionResult {
    let html: String
    let nextLineNo: Int
    let nextCursorBefore: Int
    let nextCursorAfter: Int
}

/// Emit the region of untouched "after" lines from
/// `cursorAfter` through `gapEnd` (inclusive, 1-based).
/// Small gaps (≤ `gapCollapseThreshold`) render as
/// normal context rows. Larger gaps emit a single
/// spacer row — the `data-line` slots for the hidden
/// rows are *reserved* by advancing `lineNo`, so when
/// the user expands the gap the revealed rows get
/// predictable, non-colliding IDs that stable-anchor
/// any annotations attached to them.
private func emitGapRegion(
    afterLines: [String],
    cursorBefore: Int,
    cursorAfter: Int,
    gapEnd: Int,
    fileIndex: Int,
    gapIndex: Int,
    position: GapPosition,
    language: String,
    startingLineNo: Int,
    fileAttrs: String
) -> GapEmissionResult {
    let gapStart = cursorAfter
    let gapSize = gapEnd - gapStart + 1

    if gapSize <= 0 {
        return GapEmissionResult(
            html: "",
            nextLineNo: startingLineNo,
            nextCursorBefore: cursorBefore,
            nextCursorAfter: cursorAfter
        )
    }

    // Small gap: render fully, no spacer.
    if gapSize <= gapCollapseThreshold {
        var html = ""
        var lineNo = startingLineNo
        var cb = cursorBefore
        var ca = cursorAfter
        while ca <= gapEnd, ca <= afterLines.count {
            let text = afterLines[ca - 1]
            html += renderContextRow(
                oldNo: cb,
                newNo: ca,
                dataLine: lineNo,
                content: text,
                fileAttrs: fileAttrs
            )
            cb += 1
            ca += 1
            lineNo += 1
        }
        return GapEmissionResult(
            html: html,
            nextLineNo: lineNo,
            nextCursorBefore: cb,
            nextCursorAfter: ca
        )
    }

    // Large gap: emit a spacer and reserve the data-line
    // slots the hidden rows would have consumed.
    let gapId = "f\(fileIndex)g\(gapIndex)"
    let spacerHTML = renderGapSpacer(
        gapId: gapId,
        fileIndex: fileIndex,
        language: language,
        afterStart: gapStart,
        afterEnd: gapEnd,
        beforeStart: cursorBefore,
        dataLineStart: startingLineNo,
        totalSize: gapSize,
        position: position,
        fileAttrs: fileAttrs
    )

    return GapEmissionResult(
        html: spacerHTML,
        nextLineNo: startingLineNo + gapSize,
        nextCursorBefore: cursorBefore + gapSize,
        nextCursorAfter: cursorAfter + gapSize
    )
}

/// Build the HTML for a collapsed-gap spacer row.
///
/// Branches on (position, size):
/// - SOF: one button `↑ Show lines above` — behavior
///   reveals bottom-of-gap (lines just before the
///   first hunk). Class `gap-expand-bottom` → maps to
///   `direction='down'` in JS.
/// - EOF: one button `↓ Show lines below` — behavior
///   reveals top-of-gap (lines just after the last
///   hunk). Class `gap-expand-top` → `direction='up'`.
/// - Middle stacked (size > step): two buttons. Top
///   is `↓ Show lines below` (reveals top-of-gap);
///   bottom is `↑ Show lines above` (reveals bottom-
///   of-gap). Labels describe revealed lines relative
///   to the adjacent hunk, not the spacer.
/// - Middle combined (size ≤ step): one `↕ Show N
///   lines` button reveals everything.
/// - Small SOF/EOF (size ≤ step): single directional
///   button matching the SOF/EOF arrow, with count
///   in the label.
///
/// The center "show all N unchanged lines" button
/// renders in every variant and fully reveals on
/// click.
///
/// All metadata the JS expansion handler needs lives
/// on `<tr>` data attributes, including
/// `data-gap-position` so JS re-emission preserves
/// the position branch.
private func renderGapSpacer(
    gapId: String,
    fileIndex: Int,
    language: String,
    afterStart: Int,
    afterEnd: Int,
    beforeStart: Int,
    dataLineStart: Int,
    totalSize: Int,
    position: GapPosition,
    fileAttrs: String
) -> String {
    let isStacked = totalSize > gapExpandStep
    let sizeClass = isStacked ? "gap-stacked" : "gap-combined"
    let rowClass = "unchanged-gap \(position.rowClass) "
        + sizeClass
    let allLabel = "\u{2026} show all \(totalSize) "
        + "unchanged lines \u{2026}"

    var arrowButtons = "<div class=\"gap-expand-group\">"
    switch position {
    case .sof:
        // Only the "above" button. Class
        // `gap-expand-bottom` → reveals bottom-of-gap
        // (lines closest to the first hunk). Count
        // included on small-gap variant so the user
        // sees exactly how much they'd reveal.
        let label = isStacked
            ? "Show lines above"
            : "Show \(totalSize) lines"
        arrowButtons +=
            "<button type=\"button\""
            + " class=\"gap-expand gap-expand-bottom\">"
            + "<span class=\"gap-arrow\">\u{2191}</span>"
            + "<span class=\"gap-btn-label\">"
            + label + "</span></button>"
    case .eof:
        // Only the "below" button. Class
        // `gap-expand-top` → reveals top-of-gap (lines
        // closest to the last hunk).
        let label = isStacked
            ? "Show lines below"
            : "Show \(totalSize) lines"
        arrowButtons +=
            "<button type=\"button\""
            + " class=\"gap-expand gap-expand-top\">"
            + "<span class=\"gap-arrow\">\u{2193}</span>"
            + "<span class=\"gap-btn-label\">"
            + label + "</span></button>"
    case .middle:
        if isStacked {
            // Top button: ↓ Show lines below, reveals
            // top-of-gap (its reference is the prev
            // hunk above, lines appear below that
            // reference).
            arrowButtons +=
                "<button type=\"button\""
                + " class=\"gap-expand gap-expand-top\">"
                + "<span class=\"gap-arrow\">"
                + "\u{2193}</span>"
                + "<span class=\"gap-btn-label\">"
                + "Show lines below"
                + "</span></button>"
            // Bottom button: ↑ Show lines above,
            // reveals bottom-of-gap (reference is the
            // next hunk below; lines appear above
            // that reference).
            arrowButtons +=
                "<button type=\"button\""
                + " class=\"gap-expand"
                + " gap-expand-bottom\">"
                + "<span class=\"gap-arrow\">"
                + "\u{2191}</span>"
                + "<span class=\"gap-btn-label\">"
                + "Show lines above"
                + "</span></button>"
        } else {
            arrowButtons +=
                "<button type=\"button\""
                + " class=\"gap-expand"
                + " gap-expand-combined\">"
                + "<span class=\"gap-arrow\">"
                + "\u{2195}</span>"
                + "<span class=\"gap-btn-label\">"
                + "Show \(totalSize) lines"
                + "</span></button>"
        }
    }
    arrowButtons += "</div>"

    return
        "<tr class=\"\(rowClass)\""
        + " data-kind=\"gap\""
        + " data-gap-id=\"\(gapId)\""
        + " data-gap-position=\"\(position.htmlValue)\""
        + " data-file-index=\"\(fileIndex)\""
        + " data-gap-lang=\"\(htmlEscape(language))\""
        + " data-gap-after-start=\"\(afterStart)\""
        + " data-gap-after-end=\"\(afterEnd)\""
        + " data-gap-before-start=\"\(beforeStart)\""
        + " data-gap-data-line-start=\"\(dataLineStart)\""
        + " data-top-revealed=\"0\""
        + " data-bottom-revealed=\"0\""
        + fileAttrs
        + ">"
        + "<td colspan=\"4\" class=\"gap-spacer\">"
        + "<div class=\"gap-spacer-inner\">"
        + arrowButtons
        + "<div class=\"gap-all-wrap\">"
        + "<button type=\"button\""
        + " class=\"gap-expand gap-expand-all\">"
        + "<span class=\"gap-hidden-count\">"
        + allLabel + "</span>"
        + "</button>"
        + "</div></div></td></tr>"
}

/// Serialize per-file `after` line arrays for injection
/// into the WebView. The JS expansion handler pulls
/// revealed-line content from `window.GALAXY_AFTERLINES
/// [fileIndex]`. Files with no `after` content (binary,
/// deleted) become empty arrays — their cards don't have
/// collapsible gaps anyway.
private func buildAfterLinesJS(
    files: [GdiffFile]
) -> String {
    let arrays: [[String]] = files.map { file in
        splitLines(file.after ?? "")
    }
    guard let data = try? JSONSerialization.data(
        withJSONObject: arrays,
        options: []
    ), let json = String(
        data: data, encoding: .utf8
    ) else {
        return "window.GALAXY_AFTERLINES = [];"
    }
    // Guard against </script> sequences inside source
    // content breaking out of the script tag.
    let safe = json.replacingOccurrences(
        of: "</", with: "<\\/"
    )
    return "window.GALAXY_AFTERLINES = \(safe);"
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

// MARK: - Gap-expansion JS

/// Injected into every diff reader document. Handles
/// click events on `.gap-expand` buttons inside
/// `.unchanged-gap` spacer rows, using event
/// delegation on document. Reads gap bounds and
/// current reveal state from the spacer's data
/// attributes; pulls line content from
/// `window.GALAXY_AFTERLINES[fileIndex]`. New rows
/// re-anchor via the reserved `data-line` slots
/// assigned at initial Swift render.
///
/// GAP_EXPAND_STEP / GAP_THRESHOLD are kept in sync
/// with the Swift-side `gapExpandStep` /
/// `gapCollapseThreshold` constants above.
private let gapExpansionJS: String = """
(function() {
    var GAP_EXPAND_STEP = 30;
    var GAP_THRESHOLD = 10;

    function htmlEscape(s) {
        return String(s)
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;')
            .replace(/'/g, '&#39;');
    }

    function renderContextRow(p) {
        var body = htmlEscape(p.content);
        if (body.length === 0) body = ' ';
        // Tag gap-revealed rows with `data-gap-id` so
        // subsequent expand clicks can find and clean
        // up previously-revealed siblings (they live
        // in the DOM as normal `.code-line` rows and
        // would otherwise get duplicated by the next
        // re-emission).
        var gapAttr = p.gapId
            ? ' data-gap-id="' + p.gapId + '"'
            : '';
        return '<tr class="code-line"' +
            ' data-line="' + p.dataLine + '"' +
            gapAttr +
            ' data-file-path="' +
                htmlEscape(p.filePath) + '"' +
            ' data-file-status="' +
                htmlEscape(p.fileStatus) + '"' +
            ' data-kind="context"' +
            ' data-old-line="' + p.oldNo + '"' +
            ' data-new-line="' + p.newNo + '">' +
            '<td class="line-old-num">' +
                p.oldNo + '</td>' +
            '<td class="line-new-num">' +
                p.newNo + '</td>' +
            '<td class="line-marker"></td>' +
            '<td class="line-content">' +
                body + '</td>' +
            '</tr>';
    }

    function renderGapSpacer(p) {
        var isStacked = p.hiddenCount > GAP_EXPAND_STEP;
        var position = p.position || 'middle';
        var sizeClass = isStacked
            ? 'gap-stacked' : 'gap-combined';
        var positionClass = 'gap-' + position;
        var rowClass =
            'unchanged-gap ' + positionClass +
            ' ' + sizeClass;
        var allLabel = '… show all ' + p.hiddenCount +
            ' unchanged lines …';

        var arrowButtons =
            '<div class="gap-expand-group">';
        if (position === 'sof') {
            // Only the `↑ Show lines above` button,
            // class `gap-expand-bottom` → reveals
            // bottom-of-gap (closest to first hunk).
            var sofLabel = isStacked
                ? 'Show lines above'
                : 'Show ' + p.hiddenCount + ' lines';
            arrowButtons +=
                '<button type="button"' +
                ' class="gap-expand' +
                ' gap-expand-bottom">' +
                '<span class="gap-arrow">↑</span>' +
                '<span class="gap-btn-label">' +
                sofLabel + '</span></button>';
        } else if (position === 'eof') {
            // Only the `↓ Show lines below` button,
            // class `gap-expand-top` → reveals
            // top-of-gap (closest to last hunk).
            var eofLabel = isStacked
                ? 'Show lines below'
                : 'Show ' + p.hiddenCount + ' lines';
            arrowButtons +=
                '<button type="button"' +
                ' class="gap-expand gap-expand-top">' +
                '<span class="gap-arrow">↓</span>' +
                '<span class="gap-btn-label">' +
                eofLabel + '</span></button>';
        } else if (isStacked) {
            // Middle stacked. Top = ↓ Show lines
            // below (reveals top-of-gap); bottom = ↑
            // Show lines above (reveals bottom-of-
            // gap). Labels describe revealed rows
            // relative to the adjacent hunk.
            arrowButtons +=
                '<button type="button"' +
                ' class="gap-expand gap-expand-top">' +
                '<span class="gap-arrow">↓</span>' +
                '<span class="gap-btn-label">' +
                'Show lines below' +
                '</span></button>' +
                '<button type="button"' +
                ' class="gap-expand' +
                ' gap-expand-bottom">' +
                '<span class="gap-arrow">↑</span>' +
                '<span class="gap-btn-label">' +
                'Show lines above' +
                '</span></button>';
        } else {
            // Middle combined.
            arrowButtons +=
                '<button type="button"' +
                ' class="gap-expand' +
                ' gap-expand-combined">' +
                '<span class="gap-arrow">↕</span>' +
                '<span class="gap-btn-label">' +
                'Show ' + p.hiddenCount + ' lines' +
                '</span></button>';
        }
        arrowButtons += '</div>';

        return '<tr class="' + rowClass + '"' +
            ' data-kind="gap"' +
            ' data-gap-id="' + p.gapId + '"' +
            ' data-gap-position="' + position + '"' +
            ' data-file-index="' + p.fileIndex + '"' +
            ' data-gap-lang="' +
                htmlEscape(p.lang) + '"' +
            ' data-gap-after-start="' +
                p.afterStart + '"' +
            ' data-gap-after-end="' +
                p.afterEnd + '"' +
            ' data-gap-before-start="' +
                p.beforeStart + '"' +
            ' data-gap-data-line-start="' +
                p.dataLineStart + '"' +
            ' data-top-revealed="' +
                p.topRevealed + '"' +
            ' data-bottom-revealed="' +
                p.bottomRevealed + '"' +
            ' data-file-path="' +
                htmlEscape(p.filePath) + '"' +
            ' data-file-status="' +
                htmlEscape(p.fileStatus) + '">' +
            '<td colspan="4" class="gap-spacer">' +
            '<div class="gap-spacer-inner">' +
            arrowButtons +
            '<div class="gap-all-wrap">' +
            '<button type="button"' +
            ' class="gap-expand gap-expand-all">' +
            '<span class="gap-hidden-count">' +
                allLabel + '</span>' +
            '</button>' +
            '</div></div></td></tr>';
    }

    function expandGap(spacer, direction) {
        var afterStart =
            parseInt(spacer.dataset.gapAfterStart, 10);
        var afterEnd =
            parseInt(spacer.dataset.gapAfterEnd, 10);
        var beforeStart =
            parseInt(spacer.dataset.gapBeforeStart, 10);
        var dataLineStart = parseInt(
            spacer.dataset.gapDataLineStart, 10);
        var fileIndex =
            parseInt(spacer.dataset.fileIndex, 10);
        var filePath = spacer.dataset.filePath || '';
        var fileStatus =
            spacer.dataset.fileStatus || '';
        var lang = spacer.dataset.gapLang || 'plaintext';
        var gapId = spacer.dataset.gapId || '';
        var position =
            spacer.dataset.gapPosition || 'middle';
        var totalSize = afterEnd - afterStart + 1;

        var topRevealed = parseInt(
            spacer.dataset.topRevealed, 10) || 0;
        var bottomRevealed = parseInt(
            spacer.dataset.bottomRevealed, 10) || 0;

        var afterLines =
            (window.GALAXY_AFTERLINES || [])[fileIndex]
            || [];

        if (direction === 'all') {
            topRevealed = totalSize;
            bottomRevealed = 0;
        } else if (direction === 'up') {
            topRevealed = Math.min(
                topRevealed + GAP_EXPAND_STEP,
                totalSize - bottomRevealed
            );
        } else if (direction === 'down') {
            bottomRevealed = Math.min(
                bottomRevealed + GAP_EXPAND_STEP,
                totalSize - topRevealed
            );
        } else {
            return;
        }

        // Auto-reveal the remainder if what's left is
        // below the initial collapse threshold —
        // avoids tiny residual spacers.
        var stillHidden =
            totalSize - topRevealed - bottomRevealed;
        if (stillHidden > 0 &&
            stillHidden <= GAP_THRESHOLD) {
            topRevealed = totalSize;
            bottomRevealed = 0;
        }

        var finalHidden =
            totalSize - topRevealed - bottomRevealed;

        var fragment = '';
        var i;
        // Top-revealed rows
        for (i = 0; i < topRevealed; i++) {
            fragment += renderContextRow({
                oldNo: beforeStart + i,
                newNo: afterStart + i,
                dataLine: dataLineStart + i,
                content:
                    afterLines[afterStart - 1 + i]
                    || '',
                filePath: filePath,
                fileStatus: fileStatus,
                gapId: gapId
            });
        }
        // New (smaller) spacer if still collapsed.
        // Preserve the gap's position (sof/middle/
        // eof) so re-emission shows the correct
        // button variant.
        if (finalHidden > 0) {
            fragment += renderGapSpacer({
                gapId: gapId,
                fileIndex: fileIndex,
                lang: lang,
                filePath: filePath,
                fileStatus: fileStatus,
                afterStart: afterStart,
                afterEnd: afterEnd,
                beforeStart: beforeStart,
                dataLineStart: dataLineStart,
                topRevealed: topRevealed,
                bottomRevealed: bottomRevealed,
                hiddenCount: finalHidden,
                position: position
            });
        }
        // Bottom-revealed rows
        var bottomStart = totalSize - bottomRevealed;
        for (i = 0; i < bottomRevealed; i++) {
            var offset = bottomStart + i;
            fragment += renderContextRow({
                oldNo: beforeStart + offset,
                newNo: afterStart + offset,
                dataLine: dataLineStart + offset,
                content:
                    afterLines[afterStart - 1 + offset]
                    || '',
                filePath: filePath,
                fileStatus: fileStatus,
                gapId: gapId
            });
        }

        // Find every row currently attached to this
        // gap — the clicked spacer plus any context
        // rows revealed by prior clicks. Without this
        // cleanup, earlier clicks' revealed rows
        // linger in the DOM and duplicate lines on
        // the next re-emission.
        var tbody = spacer.parentNode;
        var gapNodes = Array.prototype.slice.call(
            tbody.querySelectorAll(
                '[data-gap-id="' + gapId + '"]'));
        if (gapNodes.length === 0) {
            gapNodes = [spacer];
        }
        // Insertion anchor — the first sibling after
        // the last gap node. `null` is fine and means
        // "append to tbody".
        var insertBefore =
            gapNodes[gapNodes.length - 1].nextSibling;

        // Parse fragment into detached rows
        var temp = document.createElement('tbody');
        temp.innerHTML = fragment;
        var newRows = Array.prototype.slice.call(
            temp.children);

        // Remove all old gap rows, then insert fresh
        // fragment at the anchor position
        gapNodes.forEach(function(n) {
            tbody.removeChild(n);
        });
        newRows.forEach(function(row) {
            tbody.insertBefore(row, insertBefore);
        });

        // Reapply syntax highlighting to new context
        // rows (skip the possibly-re-emitted spacer)
        if (typeof hljs !== 'undefined' &&
            lang && lang !== 'plaintext') {
            newRows.forEach(function(row) {
                if (row.dataset.kind !== 'context') {
                    return;
                }
                var el = row.querySelector(
                    '.line-content');
                if (!el) return;
                el.classList.add('language-' + lang);
                hljs.highlightElement(el);
            });
        }

        // Re-anchor annotations whose target rows were
        // inside this gap. AnnotationManager snapshots
        // `.code-line` rows at init time; without a
        // rescan the newly-revealed rows aren't in its
        // block set and any annotations pointing at
        // them can't reposition.
        if (typeof AnnotationManager !== 'undefined' &&
            typeof AnnotationManager.rescanBlocks
                === 'function') {
            AnnotationManager.rescanBlocks();
        }
    }

    document.addEventListener('click', function(e) {
        var btn = e.target.closest('.gap-expand');
        if (!btn) return;
        var spacer = btn.closest('.unchanged-gap');
        if (!spacer) return;
        // Class → direction mapping. Class refers to
        // WHICH END of the gap is revealed, not the
        // visible arrow glyph — the label/arrow on the
        // button is inverted from the behavior.
        var direction = null;
        if (btn.classList.contains('gap-expand-top')) {
            direction = 'up';
        } else if (btn.classList.contains(
            'gap-expand-bottom')) {
            direction = 'down';
        } else if (btn.classList.contains(
            'gap-expand-all') ||
            btn.classList.contains(
                'gap-expand-combined')) {
            direction = 'all';
        }
        if (!direction) return;
        expandGap(spacer, direction);
    });
})();
"""

// MARK: - File Collapse Script

/// Click handler + hover tooltip for the per-file
/// collapse toggle.
///
/// State model: a single DOM class on `.file-card`.
/// Nothing persisted to Swift or JS memory — reader
/// close/reopen resets everything to expanded, same
/// as the gap-expand state model.
///
/// Tooltip: a singleton `<div class="file-tooltip">`
/// attached to `<body>` and positioned via fixed
/// coords on hover. Living outside the file-card is
/// mandatory because `.file-card { overflow: hidden }`
/// (needed to clip the inner table's square corners
/// against the card's 6px border-radius) would clip
/// any in-card tooltip on the left edge and entirely
/// below collapsed cards.
private let fileCollapseJS: String = """
(function() {
    var tooltipEl = null;
    var hoverBtn = null;

    function ensureTooltip() {
        if (tooltipEl) return tooltipEl;
        tooltipEl = document.createElement('div');
        tooltipEl.className = 'file-tooltip';
        document.body.appendChild(tooltipEl);
        return tooltipEl;
    }

    function positionTooltip(btn) {
        var tip = ensureTooltip();
        var label = btn.getAttribute('data-tooltip') || '';
        tip.textContent = label;
        // Force layout so we can measure the tooltip
        // before clamping horizontally.
        var btnRect = btn.getBoundingClientRect();
        var tipRect = tip.getBoundingClientRect();
        var left = btnRect.left + btnRect.width / 2
            - tipRect.width / 2;
        var margin = 4;
        var maxLeft = window.innerWidth - tipRect.width
            - margin;
        if (left < margin) left = margin;
        if (left > maxLeft) left = maxLeft;
        var top = btnRect.bottom + 4;
        tip.style.left = left + 'px';
        tip.style.top = top + 'px';
    }

    function showTooltip(btn) {
        var tip = ensureTooltip();
        positionTooltip(btn);
        tip.classList.add('visible');
    }

    function hideTooltip() {
        if (tooltipEl) tooltipEl.classList.remove('visible');
        hoverBtn = null;
    }

    document.addEventListener('mouseover', function(e) {
        var btn = e.target.closest('.file-collapse-toggle');
        if (!btn || btn === hoverBtn) return;
        hoverBtn = btn;
        showTooltip(btn);
    });

    document.addEventListener('mouseout', function(e) {
        if (!hoverBtn) return;
        var btn = e.target.closest('.file-collapse-toggle');
        if (btn !== hoverBtn) return;
        // Still inside the same button? Ignore.
        var related = e.relatedTarget;
        if (related && hoverBtn.contains(related)) return;
        hideTooltip();
    });

    // Dismiss the tooltip if the page scrolls — the
    // pill is position:fixed so it would otherwise
    // detach from the button.
    window.addEventListener('scroll', hideTooltip, true);

    document.addEventListener('click', function(e) {
        var btn = e.target.closest('.file-collapse-toggle');
        if (!btn) return;
        var card = btn.closest('.file-card');
        if (!card) return;

        var collapsed = !card.classList.contains('collapsed');
        card.classList.toggle('collapsed', collapsed);

        var label = collapsed ? 'Expand file' : 'Collapse file';
        btn.setAttribute('data-tooltip', label);
        btn.setAttribute('aria-label', label);
        btn.setAttribute('aria-expanded', collapsed ? 'false' : 'true');

        // If the tooltip is currently visible for this
        // button, refresh its text + position inline —
        // the mouse is still over the button but the
        // label (and possibly the button's Y after the
        // card's height changed) just changed.
        if (hoverBtn === btn) {
            positionTooltip(btn);
        }

        // Hide/show annotation cards anchored in this
        // file. Annotation cards live on document.body
        // (outside the file-card's overflow clip), so
        // the CSS collapse selector can't reach them —
        // toggle `.file-hidden` by matching
        // data-file-path. Iterating all cards and
        // string-comparing the attribute avoids the
        // CSS-attribute-value escaping headache that
        // selector-based matching would introduce for
        // paths containing special chars.
        var filePath = card.getAttribute('data-file-path');
        if (filePath) {
            var annCards = document.querySelectorAll(
                '.annotation-card');
            for (var i = 0; i < annCards.length; i++) {
                if (annCards[i].getAttribute(
                    'data-file-path') === filePath) {
                    annCards[i].classList.toggle(
                        'file-hidden', collapsed);
                }
            }
        }

        // Reposition annotation cards — the file
        // card's height just changed (body hidden or
        // revealed), so every spacer below this file
        // sits at a new Y and its card needs to follow.
        // Use syncAllPositions, NOT rescanBlocks:
        // rescan wipes and recreates every card from
        // scratch, which (a) loses the `.file-hidden`
        // tags we just applied and (b) creates fresh
        // spacers inside the now-collapsed tbody whose
        // `display:none` ancestor makes getBoundingClientRect
        // return zero, stranding cards at document top.
        // No blocks were added or removed — only CSS
        // visibility toggled — so the cached block set
        // is still valid and a positional re-sync is
        // all we need.
        if (typeof AnnotationManager !== 'undefined' &&
            typeof AnnotationManager.syncAllPositions
                === 'function') {
            AnnotationManager.syncAllPositions();
        }
    });
})();
"""

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
