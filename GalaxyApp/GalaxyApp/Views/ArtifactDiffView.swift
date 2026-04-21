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

/// Metadata on a `.gdiff` capture.
///
/// `refFrom` and `refTo` are 40-char commit SHAs when
/// the capture could resolve them, otherwise fallbacks
/// (original input like "main", or "working-tree" for
/// an uncommitted tree). `repo` is `owner/repo` for a
/// GitHub origin remote, empty string otherwise. The
/// reader treats "both refs match the SHA regex AND
/// repo is non-empty" as the signal for offering an
/// Open-on-GitHub link — no separate flag, the data
/// itself encodes linkability.
struct GdiffMetadata: Codable {
    let refFrom: String
    let refTo: String
    let repo: String
    let createdAt: String
    let summary: String

    enum CodingKeys: String, CodingKey {
        case refFrom = "ref_from"
        case refTo = "ref_to"
        case repo
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
    /// File paths (relative, as they appear in the
    /// diff) that should pre-render with the Viewed
    /// checkbox checked and the file-card collapsed.
    /// Sourced from `ViewedFilesPersistence` keyed by
    /// ledger-session + artifact number.
    let viewedFilePaths: Set<String>
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
            isDark: isDark,
            viewedFilePaths: viewedFilePaths
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
                    isDark: isDark,
                    viewedFilePaths: viewedFilePaths
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
    isDark: Bool,
    viewedFilePaths: Set<String>
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

    // Build the TOC tree first so we can use its DFS
    // order as the rendering order for file cards.
    // Without this, cards render in git's emit order
    // while the TOC groups by folder — the two
    // orderings diverge whenever git's order isn't
    // already folder-grouped (common). Rendering in
    // tree order keeps TOC and cards in lockstep so
    // scrolling past file N arrives at the file that
    // sits immediately below N in the tree.
    //
    // fileIndex stays tied to the original
    // doc.files[i] position — the TOC's
    // `data-target="file-card-N"` already uses that
    // index, so only the visual order changes; click
    // targets still resolve correctly.
    let treeRoots = buildFileTree(doc.files)
    let orderedIndices = flattenTreeFileOrder(
        treeRoots
    )
    for fileIndex in orderedIndices {
        let file = doc.files[fileIndex]
        lineCounter += 1
        let headerLine = lineCounter

        let result = renderFileCard(
            file: file,
            fileIndex: fileIndex,
            startingLine: lineCounter + 1,
            headerLine: headerLine,
            isViewed: viewedFilePaths.contains(
                file.path
            )
        )
        cardsHTML += result.html
        lineCounter = result.nextLine
    }

    // Serialize per-file "after" line arrays for
    // client-side gap expansion. JS reads from
    // `window.GALAXY_AFTERLINES[fileIndex]` when a user
    // clicks an unchanged-region expand affordance.
    let afterLinesJS = buildAfterLinesJS(files: doc.files)

    // TOC side panel. `treeRoots` was built above so
    // the card rendering loop could iterate in DFS
    // order — reusing it here avoids a duplicate
    // tree-build pass.
    let sidebarHTML = renderFileTree(treeRoots)
    let bodyLayoutHTML =
        "<div class=\"diff-body\">"
        + sidebarHTML
        + "<main class=\"main-column\">"
        + cardsHTML
        + "</main>"
        + "</div>"

    // Summary header at top of document.
    //
    // SHAs get truncated to 7 chars for display, which
    // is long enough to be unambiguous in every
    // repository I'd ever look at; non-SHA refs (the
    // "working-tree" marker, unresolvable inputs) pass
    // through as-is. The ref pair is always plain
    // text. When both refs are SHAs and repo is
    // non-empty, a separate "View on GitHub" link with
    // the GitHub mark is pushed to the right edge of
    // the header. Otherwise that slot is empty.
    let metadataHTML =
        "<div class=\"diff-summary\">"
        + "<span class=\"diff-summary-refs\">"
        + renderRefPair(doc.metadata)
        + "</span>"
        + "<span class=\"diff-summary-sep\">&middot;</span>"
        + "<span class=\"diff-summary-stats\">"
        + htmlEscape(doc.metadata.summary)
        + "</span>"
        + renderGitHubLink(doc.metadata)
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
    .diff-summary-refs {
        font-family: ui-monospace, monospace;
    }
    /* "View on GitHub" affordance — pushed to the
       right edge of the header via margin-left:auto
       (the summary flexbox flows left-to-right, so
       auto-margin consumes the remaining space).
       Underline only on hover keeps the header calm
       when idle. `target="_blank" rel="noopener"` on
       the anchor itself lets the WKNavigationDelegate
       in AnnotationSupport route the click through
       NSWorkspace.open rather than navigating the
       WKWebView. */
    .diff-summary-link {
        margin-left: auto;
        display: inline-flex;
        align-items: center;
        gap: 6px;
        color: \(blueFg);
        text-decoration: none;
    }
    .diff-summary-link:hover {
        text-decoration: underline;
    }
    .diff-summary-gh-mark {
        /* Nudge the mark down a hair so its optical
           center aligns with the x-height of the
           adjacent text (the glyph's visual weight
           sits below geometric center). */
        transform: translateY(0.5px);
    }
    .diff-summary-sep {
        opacity: 0.5;
    }
    /* Two-column layout: TOC sidebar on the left,
       file cards in the main column. align-items
       flex-start so the sidebar doesn't stretch to
       the full content height — the sidebar is its
       own scroll container via max-height +
       overflow-y below. */
    .diff-body {
        display: flex;
        align-items: flex-start;
        gap: 16px;
    }
    .main-column {
        flex: 1 1 auto;
        /* Constrain so long file paths wrap inside
           the card instead of expanding the main
           column and pushing the sidebar off-screen.
           min-width:0 is the standard flex-item fix
           for "child with overflow pushes parent". */
        min-width: 0;
    }
    /* TOC sidebar. Sticky-top so it stays put while
       the main column scrolls; own scroll container
       so a long tree doesn't push everything below
       the viewport. */
    .toc-sidebar {
        flex: 0 0 260px;
        width: 260px;
        position: sticky;
        top: 12px;
        max-height: calc(100vh - 24px);
        overflow-y: auto;
        padding: 8px 4px;
        background: \(headerBg);
        border: 1px solid \(borderColor);
        border-radius: 6px;
        font-family: -apple-system, system-ui,
            sans-serif;
        font-size: 12px;
    }
    .toc-list {
        list-style: none;
        padding: 0;
        margin: 0;
    }
    /* Folder + file rows share this button-based
       clickable area. Buttons (not <a>s) because
       they're in-page actions (collapse / scroll),
       not navigation targets. */
    .toc-folder-label, .toc-file-label {
        display: flex;
        align-items: center;
        gap: 6px;
        width: 100%;
        padding: 3px 8px 3px var(--toc-indent, 8px);
        background: transparent;
        border: 0;
        color: \(textColor);
        font: inherit;
        cursor: pointer;
        text-align: left;
        border-radius: 4px;
        white-space: nowrap;
        overflow: hidden;
    }
    .toc-folder-label:hover,
    .toc-file-label:hover {
        background: \(hoverBg);
    }
    .toc-folder-name, .toc-file-name {
        overflow: hidden;
        text-overflow: ellipsis;
    }
    .toc-folder-name {
        font-family: ui-monospace, monospace;
        color: \(mutedFg);
    }
    .toc-file-name {
        font-family: ui-monospace, monospace;
    }
    /* Chevron rotates when the parent folder
       collapses — one SVG, two visual states. */
    .toc-chevron {
        flex: 0 0 12px;
        transition: transform 0.15s ease;
        color: \(mutedFg);
    }
    .toc-folder.collapsed
        > .toc-folder-label .toc-chevron {
        transform: rotate(-90deg);
    }
    .toc-folder.collapsed > .toc-children {
        display: none;
    }
    /* Status badges — compact single-letter pills
       matching the file-card header's colors so
       both views speak the same visual language. */
    .toc-status {
        flex: 0 0 16px;
        display: inline-flex;
        align-items: center;
        justify-content: center;
        width: 16px;
        height: 16px;
        border-radius: 3px;
        font-size: 10px;
        font-weight: 600;
        font-family: ui-monospace, monospace;
        line-height: 1;
    }
    .toc-status-added {
        background: \(greenBg); color: \(greenFg);
    }
    .toc-status-modified {
        background: \(yellowBg); color: \(yellowFg);
    }
    .toc-status-deleted {
        background: \(redBg); color: \(redFg);
    }
    .toc-status-renamed {
        background: \(blueBg); color: \(blueFg);
    }
    .toc-status-binary {
        background: \(hoverBg); color: \(mutedFg);
    }
    /* Annotation cards are absolute-positioned
       relative to the viewport (defined in
       annotationCSS, which is shared with the other
       readers and stays at left:24px right:24px so
       markdown/table/etc. render correctly). In the
       diff reader the main content sits in a
       276px-indented column (sidebar 260 + gap 16),
       so full-viewport-width annotations would
       extend under the sidebar. Shift `left` by the
       sidebar offset when the sidebar is present —
       `:has(.toc-sidebar)` scopes this to diffs
       that actually rendered one (empty-state diffs
       skip the sidebar and keep the default left).
       The annotationCSS rules still win for any
       reader that doesn't have a toc-sidebar. */
    body:has(.toc-sidebar) .annotation-card,
    body:has(.toc-sidebar) .annotation-form {
        left: calc(24px + 276px);
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
        /* `overflow: clip` clips the inner table's
           square corners against the 6px border-radius
           just like `overflow: hidden` would, but
           (unlike hidden) does NOT establish a scroll
           container. That matters because
           `position: sticky` on descendants walks up
           to the nearest scroll container to decide
           where to sticky — hidden would trap the
           sticky header inside the non-scrolling card
           and make it a no-op. `clip` keeps the
           viewport as the sticky container so the
           header pins to the top of the page while
           the card body scrolls behind it. */
        overflow: clip;
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
    /* Viewed checkbox — GitHub-style affordance next
       to the file stats. Clicking it toggles the
       file-card's `.collapsed` class (same mechanism
       the chevron uses) and posts a setViewed message
       to Swift for per-session persistence. */
    .file-viewed {
        display: inline-flex;
        align-items: center;
        gap: 4px;
        font-size: 12px;
        color: \(mutedFg);
        cursor: pointer;
        user-select: none;
        -webkit-user-select: none;
        padding: 2px 6px;
        border-radius: 4px;
    }
    .file-viewed:hover { background: \(hoverBg); }
    .file-viewed input[type="checkbox"] {
        cursor: pointer;
        margin: 0;
    }
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
    /* Shared button styling for the file-header's
       icon buttons — the collapse chevron and the
       copy-path button live inside .file-header with
       the parent's `gap: 8px` handling spacing.
       `line-height: 0` prevents the SVG from
       contributing extra vertical whitespace. */
    .file-collapse-toggle,
    .file-copy-path {
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
    .file-collapse-toggle:focus-visible,
    .file-copy-path:hover,
    .file-copy-path:focus-visible {
        background: \(hoverBg);
        color: \(textColor);
        outline: none;
    }
    .file-collapse-toggle .chevron {
        transition: transform 0.12s ease-in-out;
    }
    /* Brief green flash on successful copy, paired
       with the check icon swap + "Copied!" tooltip.
       Decays back to the default muted color when
       .copied is removed. */
    .file-copy-path.copied {
        color: \(greenFg);
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
    /* Sticky file-card header — pins the file path /
       status / collapse chevron to the top of the
       viewport while the body of the card scrolls
       behind. The `:not(.collapsed)` guard keeps it
       inert for collapsed cards, where the header is
       the entire card and stickying it would just
       waste a stacking slot. z-index 20 keeps the
       header above annotation cards (z-index 10) so
       scrolling past a pinned annotation can't cover
       the file chrome. */
    .file-card:not(.collapsed) tr.header-line {
        position: sticky;
        top: 0;
        z-index: 20;
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
    \(bodyLayoutHTML)
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
    \(tocNavJS)
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
    headerLine: Int,
    isViewed: Bool
) -> FileCardResult {
    let (statusClass, statusLabel) = statusBadge(
        for: file
    )
    let (adds, dels) = countChanges(in: file.hunks)
    let lang = file.language ?? "plaintext"

    // Header row — annotatable, maps to headerLine
    let fp = htmlEscape(file.path)
    let fs = htmlEscape(file.status)
    // File-card carries its own `data-file-path` so
    // the collapse handler can match annotation cards
    // (also stamped with `data-file-path`) and hide
    // them together with the body rows. `id` on the
    // card is a separate stable handle for the TOC
    // click-to-scroll JS — file paths can contain
    // characters that are awkward in CSS attribute
    // selectors, so we use a numeric id there and
    // keep the data attribute for annotation matching.
    //
    // Pre-collapse via `.collapsed` when the file is
    // persisted as viewed — the same class the chevron
    // toggles at runtime, so the body hides and the
    // chevron rotates without any extra JS on load.
    let cardClasses = isViewed
        ? "file-card collapsed" : "file-card"
    var html =
        "<div class=\"\(cardClasses)\""
        + " id=\"file-card-\(fileIndex)\""
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

    // Chevron + Viewed checkbox share the `.collapsed`
    // class as the single source of truth. When
    // `isViewed`, render chevron with the collapsed
    // label/aria and the checkbox pre-checked.
    let chevronTooltip = isViewed
        ? "Expand file" : "Collapse file"
    let chevronExpanded = isViewed ? "false" : "true"
    let viewedChecked = isViewed ? " checked" : ""

    html +=
        "<tr class=\"code-line header-line\""
        + " data-line=\"\(headerLine)\""
        + fileAttrs
        + " data-kind=\"file-header\">"
        + "<td colspan=\"4\" class=\"line-content\">"
        + "<div class=\"file-header\">"
        + "<button type=\"button\""
        + " class=\"file-collapse-toggle\""
        + " data-tooltip=\"\(chevronTooltip)\""
        + " aria-label=\"\(chevronTooltip)\""
        + " aria-expanded=\"\(chevronExpanded)\">"
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
    // Copy-file-path button — reads the card's
    // data-file-path on click and writes to clipboard.
    // For renamed files this copies the NEW path, not
    // the old one (same as GitHub).
    html +=
        "<button type=\"button\""
        + " class=\"file-copy-path\""
        + " data-tooltip=\"Copy file path to clipboard\""
        + " aria-label=\"Copy file path to clipboard\">"
        + "<svg class=\"copy-icon\" width=\"12\""
        + " height=\"12\" viewBox=\"0 0 16 16\""
        + " aria-hidden=\"true\">"
        + "<path fill=\"currentColor\""
        + " d=\"M0 6.75C0 5.784.784 5 1.75 5h1.5a.75"
        + ".75 0 0 1 0 1.5h-1.5a.25.25 0 0 0-.25.25v7"
        + ".5c0 .138.112.25.25.25h7.5a.25.25 0 0 0 ."
        + "25-.25v-1.5a.75.75 0 0 1 1.5 0v1.5A1.75 1"
        + ".75 0 0 1 9.25 16h-7.5A1.75 1.75 0 0 1 0 "
        + "14.25Z\"/>"
        + "<path fill=\"currentColor\""
        + " d=\"M5 1.75C5 .784 5.784 0 6.75 0h7.5C15"
        + ".216 0 16 .784 16 1.75v7.5A1.75 1.75 0 0 "
        + "1 14.25 11h-7.5A1.75 1.75 0 0 1 5 9.25Zm1"
        + ".75-.25a.25.25 0 0 0-.25.25v7.5c0 .138.11"
        + "2.25.25.25h7.5a.25.25 0 0 0 .25-.25v-7.5a"
        + ".25.25 0 0 0-.25-.25Z\"/>"
        + "</svg>"
        + "</button>"
    html +=
        "<span class=\"status-badge "
        + statusClass + "\">"
        + statusLabel + "</span>"
    html +=
        "<span class=\"file-stats\">"
        + "<span class=\"stat-add\">+\(adds)</span>"
        + " <span class=\"stat-del\">-\(dels)</span>"
        + "</span>"
    // Viewed checkbox — right-aligned after the file
    // stats. Clicking it toggles `.collapsed` on the
    // file-card (same mechanism the chevron uses) and
    // posts a `setViewed` message so Swift persists
    // the state per session + artifact.
    html +=
        "<label class=\"file-viewed\">"
        + "<input type=\"checkbox\""
        + "\(viewedChecked)> Viewed"
        + "</label>"
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

// MARK: - Inline Diff

/// Computes word-level highlights for a delete/add
/// line pair using Myers' O(ND) diff over tokens.
/// Returns (delHTML, addHTML) with
/// <span class="char-del"> / <span class="char-add">
/// wrapping changed runs. Falls back to `nil, nil`
/// if the diff is degenerate (identical, one side
/// empty) or runs past its wall-clock deadline.
///
/// Tokenizing before diffing produces word-scale
/// output spans rather than the per-character
/// "speckle" a char-level Myers alone would emit —
/// so a rename like `user_id → account_id` renders
/// as one del span + one add span instead of
/// several scattered single-char fragments.
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

    let delTokens = tokenize(delLine)
    let addTokens = tokenize(addLine)

    // Compute diff ops with Myers' O((N+M)·D)
    // algorithm over tokens (word runs, whitespace
    // runs, single punctuation chars). Fewer symbols
    // than char-level → the 50ms deadline almost
    // never trips in practice, and the output is
    // word-granular by construction so we don't need
    // a post-pass to avoid char-level "speckle".
    let deadline = CFAbsoluteTimeGetCurrent() + 0.050
    guard let ops = myersDiff(
        delTokens, addTokens, deadline: deadline
    ) else {
        return (nil, nil)
    }

    var delHTML = ""
    var addHTML = ""
    var delSpanOpen = false
    var addSpanOpen = false

    for op in ops {
        switch op {
        case .equal(let tok):
            if delSpanOpen {
                delHTML += "</span>"
                delSpanOpen = false
            }
            if addSpanOpen {
                addHTML += "</span>"
                addSpanOpen = false
            }
            let escaped = htmlEscape(String(tok))
            delHTML += escaped
            addHTML += escaped
        case .delete(let tok):
            if !delSpanOpen {
                delHTML += "<span class=\"char-del\">"
                delSpanOpen = true
            }
            delHTML += htmlEscape(String(tok))
        case .insert(let tok):
            if !addSpanOpen {
                addHTML += "<span class=\"char-add\">"
                addSpanOpen = true
            }
            addHTML += htmlEscape(String(tok))
        }
    }
    if delSpanOpen { delHTML += "</span>" }
    if addSpanOpen { addHTML += "</span>" }

    return (delHTML, addHTML)
}

/// Splits a line into tokens for word-level diffing.
/// Word chars (letters, digits, `_`) collapse into
/// runs, whitespace collapses into runs, and every
/// other char is its own token. Matches the
/// "words + whitespace + single punct" scheme used
/// by `wdiff` and diff-match-patch's token mode.
private func tokenize(_ s: String) -> [Substring] {
    var tokens: [Substring] = []
    var i = s.startIndex
    while i < s.endIndex {
        let start = i
        let ch = s[i]
        if ch.isLetter || ch.isNumber || ch == "_" {
            // Word run
            while i < s.endIndex {
                let c = s[i]
                guard c.isLetter || c.isNumber
                    || c == "_"
                else { break }
                i = s.index(after: i)
            }
        } else if ch.isWhitespace {
            // Whitespace run
            while i < s.endIndex,
                  s[i].isWhitespace
            {
                i = s.index(after: i)
            }
        } else {
            // Single non-word, non-whitespace char
            i = s.index(after: i)
        }
        tokens.append(s[start..<i])
    }
    return tokens
}

private enum DiffOp<Element> {
    case equal(Element)
    case delete(Element)
    case insert(Element)
}

/// Myers' O(ND) difference algorithm. Returns a
/// forward-order stream of `.equal` / `.delete` /
/// `.insert` ops that transform `a` into `b`.
///
/// Generic over `Element: Equatable` so the same
/// algorithm serves both char- and token-level
/// diffs — the caller chooses the granularity by
/// picking the element type.
///
/// Time is O((N+M)·D) where D is the edit distance —
/// "output-sensitive" — so a small edit in a long
/// sequence is fast regardless of length. Memory is
/// O(D·(N+M)) for the backtrace snapshots; the
/// linear-space refinement isn't needed at typical
/// diff-line sizes. See: Eugene W. Myers, "An O(ND)
/// Difference Algorithm and Its Variations",
/// Algorithmica (1986) 1:251-266.
///
/// `deadline` is a soft wall-clock cap, consulted
/// once per `d` iteration. For adversarial inputs
/// where D approaches N+M the algorithm degenerates
/// toward quadratic cost; returning nil on deadline
/// lets the caller fall back to row-only highlighting
/// rather than blocking the render. In practice the
/// deadline almost never trips — typical modified
/// lines have tiny edit distances, especially at
/// token granularity.
private func myersDiff<T: Equatable>(
    _ a: [T],
    _ b: [T],
    deadline: CFAbsoluteTime
) -> [DiffOp<T>]? {
    let n = a.count
    let m = b.count
    if n == 0 {
        return b.map { .insert($0) }
    }
    if m == 0 {
        return a.map { .delete($0) }
    }

    let maxD = n + m
    // V[k] = furthest-reaching x on diagonal k
    // (where k = x - y). Offset by maxD so negative
    // diagonals index into the array safely.
    var v = Array(
        repeating: 0, count: 2 * maxD + 1
    )
    // Snapshot of V at each d — consulted during
    // backtrace to follow the edit path in reverse.
    var trace: [[Int]] = []

    for d in 0...maxD {
        // Deadline is checked once per d (not per k)
        // — coarse enough to be cheap, fine enough
        // that a runaway can't run for more than one
        // full diagonal sweep past the deadline.
        if CFAbsoluteTimeGetCurrent() > deadline {
            return nil
        }

        trace.append(v)
        var k = -d
        while k <= d {
            var x: Int
            // Choose whether to extend the path from
            // the diagonal above (insert, moving
            // down) or below (delete, moving right).
            // The boundary conditions force the only
            // legal move when k is at ±d.
            if k == -d ||
                (k != d &&
                 v[k - 1 + maxD] < v[k + 1 + maxD])
            {
                x = v[k + 1 + maxD]
            } else {
                x = v[k - 1 + maxD] + 1
            }
            var y = x - k
            // Extend along the "snake" — consecutive
            // equal characters cost nothing.
            while x < n && y < m && a[x] == b[y] {
                x += 1
                y += 1
            }
            v[k + maxD] = x
            if x >= n && y >= m {
                return myersBacktrace(
                    a: a, b: b, trace: trace
                )
            }
            k += 2
        }
    }

    // Unreachable for valid inputs — every string
    // pair has D ≤ N+M so the loop above always
    // finds the end within that bound.
    return nil
}

/// Walks the V snapshots produced by `myersDiff` in
/// reverse to recover the edit script. Emits ops
/// from end to start, then reverses the result so the
/// caller consumes them in forward order.
private func myersBacktrace<T: Equatable>(
    a: [T],
    b: [T],
    trace: [[Int]]
) -> [DiffOp<T>] {
    let n = a.count
    let m = b.count
    let maxD = n + m
    var ops: [DiffOp<T>] = []
    var x = n
    var y = m

    for d in stride(
        from: trace.count - 1,
        through: 0,
        by: -1
    ) {
        let v = trace[d]
        let k = x - y
        // Which neighbor diagonal did we come from?
        // Mirrors the forward-move decision — same
        // rule must choose the same edge, or the
        // reconstructed path won't line up with the
        // one myersDiff took.
        let prevK: Int
        if k == -d ||
            (k != d &&
             v[k - 1 + maxD] < v[k + 1 + maxD])
        {
            prevK = k + 1
        } else {
            prevK = k - 1
        }
        let prevX = v[prevK + maxD]
        let prevY = prevX - prevK

        // Walk back along the snake, emitting equals
        // for every step.
        while x > prevX && y > prevY {
            ops.append(.equal(a[x - 1]))
            x -= 1
            y -= 1
        }

        // d == 0 means we're back at the origin —
        // no edit op to emit.
        if d > 0 {
            if x == prevX {
                // Came from diagonal above → insert
                ops.append(.insert(b[y - 1]))
                y -= 1
            } else {
                // Came from diagonal below → delete
                ops.append(.delete(a[x - 1]))
                x -= 1
            }
        }
    }

    return ops.reversed()
}

// MARK: - Header Ref Rendering

/// Renders the `refFrom → refTo` text for the summary
/// header — always plain (not a link). SHAs truncate
/// to 7 chars; non-SHA refs (the "working-tree"
/// marker, unresolvable inputs) pass through as-is.
private func renderRefPair(
    _ metadata: GdiffMetadata
) -> String {
    htmlEscape(displayRef(metadata.refFrom))
        + " → "
        + htmlEscape(displayRef(metadata.refTo))
}

/// Renders the "View on GitHub" affordance (GitHub
/// mark SVG + text) when the capture has enough
/// metadata to build a compare URL: repo non-empty,
/// both refs SHA-shape. Returns empty string when any
/// gate fails (working-tree captures, unresolvable
/// refs, non-GitHub remotes) — the caller interpolates
/// unconditionally and the empty string leaves the
/// header's right slot blank.
private func renderGitHubLink(
    _ metadata: GdiffMetadata
) -> String {
    guard !metadata.repo.isEmpty,
          isSHA(metadata.refFrom),
          isSHA(metadata.refTo)
    else {
        return ""
    }

    let url = "https://github.com/"
        + metadata.repo
        + "/compare/"
        + metadata.refFrom
        + "..."
        + metadata.refTo

    return "<a class=\"diff-summary-link\" href=\""
        + htmlEscape(url)
        + "\" target=\"_blank\" rel=\"noopener\">"
        + githubMarkSVG()
        + "<span>View on GitHub</span>"
        + "</a>"
}

/// Inline GitHub mark (Octicons `mark-github`,
/// 16×16). `fill="currentColor"` so the glyph picks
/// up the link's text color automatically and tracks
/// light/dark mode without a separate theme variant.
///
/// The path is concatenated segment-by-segment rather
/// than using a multiline literal with escape-newline
/// continuations — the latter is sensitive to leading
/// indentation stripping and one stray space would
/// corrupt the SVG path's compact `-`-separated
/// number syntax.
private func githubMarkSVG() -> String {
    let path = ""
        + "M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53"
        + " 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01"
        + "-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94"
        + "-.09-.23-.48-.94-.82-1.13-.28-.15-.68"
        + "-.52-.01-.53.63-.01 1.08.58 1.23.82.72"
        + " 1.21 1.87.87 2.33.66.07-.52.28-.87.51"
        + "-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87"
        + ".31-1.59.82-2.15-.08-.2-.36-1.02.08"
        + "-2.12 0 0 .67-.21 2.2.82.64-.18 1.32"
        + "-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04"
        + " 2.2-.82 2.2-.82.44 1.1.16 1.92.08"
        + " 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87"
        + " 3.75-3.65 3.95.29.25.54.73.54 1.48 0"
        + " 1.07-.01 1.93-.01 2.2 0 .21.15.46.55"
        + ".38A8.013 8.013 0 0016 8c0-4.42-3.58-8"
        + "-8-8z"

    return "<svg class=\"diff-summary-gh-mark\""
        + " viewBox=\"0 0 16 16\" width=\"14\""
        + " height=\"14\" fill=\"currentColor\""
        + " aria-hidden=\"true\">"
        + "<path d=\"\(path)\"/></svg>"
}

/// Short display form for a ref: SHAs truncate to 7
/// chars, everything else passes through (so
/// "working-tree" and fallback branch names render as
/// themselves).
private func displayRef(_ ref: String) -> String {
    isSHA(ref) ? String(ref.prefix(7)) : ref
}

/// Matches a full-length Git commit SHA — exactly 40
/// lowercase hex chars. Tight on purpose: any other
/// string (branch names, "working-tree", partial
/// SHAs) returns false, which is what gates the
/// compare-link affordance.
private func isSHA(_ s: String) -> Bool {
    guard s.count == 40 else { return false }
    return s.allSatisfy {
        ($0 >= "0" && $0 <= "9")
            || ($0 >= "a" && $0 <= "f")
    }
}

// MARK: - File Tree (TOC Sidebar)

/// A node in the TOC file tree. `.folder` groups one
/// or more path segments as a single label (path
/// compression collapses single-child folder chains
/// into `app/models/ai/tools/mcp`-style labels);
/// `.file` is a leaf wrapping the real GdiffFile
/// and its index in the flat files array (used as
/// the click-target `file-card-N` id).
private indirect enum TreeNode {
    case folder(label: String, children: [TreeNode])
    case file(file: GdiffFile, index: Int)
}

/// Builds the TOC file tree from the flat files
/// array. Splits each file's path on `/`, inserts
/// into a nested intermediate structure, then
/// compresses chains of single-child subfolders
/// (no file children, exactly one subfolder) into a
/// single folder node whose label joins the
/// segments back with `/`. File children stop the
/// chain — a folder is never merged with a file
/// leaf, so the folder header always stays visible
/// above its files (matching the reference UI).
private func buildFileTree(
    _ files: [GdiffFile]
) -> [TreeNode] {
    // Mutable intermediate node. Reference semantics
    // make the insertion loop read cleanly; the
    // compression pass converts to immutable
    // TreeNodes on the way out.
    final class Build {
        var sub: [String: Build] = [:]
        // Preserve segment insertion order so two
        // sibling subfolders render in the order
        // their files first appeared, not hash order.
        var subOrder: [String] = []
        var files: [(file: GdiffFile, idx: Int)] = []
    }

    let root = Build()
    for (idx, file) in files.enumerated() {
        let parts = file.path
            .split(
                separator: "/",
                omittingEmptySubsequences: true
            )
            .map(String.init)
        guard !parts.isEmpty else {
            // Root-level file (no path segments) —
            // shouldn't normally happen in git diffs
            // but defensive against weird inputs.
            root.files.append((file, idx))
            continue
        }

        var cursor = root
        for segment in parts.dropLast() {
            if let existing = cursor.sub[segment] {
                cursor = existing
            } else {
                let next = Build()
                cursor.sub[segment] = next
                cursor.subOrder.append(segment)
                cursor = next
            }
        }
        cursor.files.append((file, idx))
    }

    // Recursive compression: for each subfolder,
    // walk its single-child chain as long as the
    // current node has no files AND exactly one
    // subfolder. Emit a folder node whose label is
    // the joined chain, then recurse into whatever
    // we stopped at.
    func compressFolder(
        label: String, build: Build
    ) -> TreeNode {
        var currentLabel = label
        var current = build
        while current.files.isEmpty
            && current.sub.count == 1,
              let onlySegment = current.subOrder.first,
              let onlyChild = current.sub[onlySegment]
        {
            currentLabel += "/\(onlySegment)"
            current = onlyChild
        }
        return .folder(
            label: currentLabel,
            children: flatten(current)
        )
    }

    func flatten(_ build: Build) -> [TreeNode] {
        var result: [TreeNode] = []
        for segment in build.subOrder {
            guard let child = build.sub[segment]
            else { continue }
            result.append(compressFolder(
                label: segment, build: child
            ))
        }
        for (file, idx) in build.files {
            result.append(
                .file(file: file, index: idx)
            )
        }
        return result
    }

    return flatten(root)
}

/// Walks the built tree in depth-first order and
/// returns the original `doc.files` indices in that
/// order. Used by `buildDiffHTML` to render cards
/// in the same order the TOC lists them, so a user
/// scrolling past file N arrives at the file that
/// visually sits below N in the tree — no jumping
/// across unrelated folders.
private func flattenTreeFileOrder(
    _ roots: [TreeNode]
) -> [Int] {
    var result: [Int] = []
    func visit(_ node: TreeNode) {
        switch node {
        case let .folder(_, children):
            for child in children { visit(child) }
        case let .file(_, index):
            result.append(index)
        }
    }
    for root in roots { visit(root) }
    return result
}

/// Emits the full `<nav class="toc-sidebar">` HTML
/// for the tree. Returns "" if there are no nodes
/// so the caller can conditionally skip the flex
/// wrapper entirely on empty-diff renders.
private func renderFileTree(
    _ roots: [TreeNode]
) -> String {
    if roots.isEmpty { return "" }
    var html = "<nav class=\"toc-sidebar\""
    html += " aria-label=\"File tree\">"
    html += "<ul class=\"toc-list toc-root\">"
    for node in roots {
        html += renderTreeNode(node, depth: 0)
    }
    html += "</ul></nav>"
    return html
}

/// Renders one tree node (and its subtree). Depth is
/// used for horizontal indent — written to a CSS
/// custom property via inline style so one CSS rule
/// (`padding-left: var(--toc-indent)`) covers every
/// nesting level without per-depth selectors.
private func renderTreeNode(
    _ node: TreeNode, depth: Int
) -> String {
    // 12px per nesting level, 8px base inset so the
    // leftmost items aren't flush with the sidebar's
    // inner padding.
    let indent = depth * 12 + 8
    switch node {
    case let .folder(label, children):
        var html = "<li class=\"toc-folder\""
        html += " style=\"--toc-indent: \(indent)px;"
        html += "\">"
        html += "<button type=\"button\""
        html += " class=\"toc-folder-label\""
        html += " aria-expanded=\"true\">"
        html += tocChevronSVG()
        html += "<span class=\"toc-folder-name\">"
        html += htmlEscape(label)
        html += "/</span></button>"
        html += "<ul class=\"toc-list toc-children\">"
        for child in children {
            html += renderTreeNode(
                child, depth: depth + 1
            )
        }
        html += "</ul></li>"
        return html

    case let .file(file, index):
        // Use trailing-path-segment for display —
        // the folder label already covers the
        // directory context.
        let leafName = file.path
            .split(separator: "/")
            .last
            .map(String.init) ?? file.path
        let (statusClass, letter) = tocStatusIcon(
            for: file
        )
        var html = "<li class=\"toc-file\""
        html += " style=\"--toc-indent: \(indent)px;"
        html += "\">"
        html += "<button type=\"button\""
        html += " class=\"toc-file-label\""
        html += " data-target=\"file-card-\(index)\""
        html += " title=\""
        html += htmlEscape(file.path)
        html += "\">"
        html += "<span class=\"toc-status \(statusClass)"
        html += "\" aria-hidden=\"true\">\(letter)"
        html += "</span>"
        html += "<span class=\"toc-file-name\">"
        html += htmlEscape(leafName)
        html += "</span></button></li>"
        return html
    }
}

/// Status icon class + single-letter glyph for the
/// TOC. Uses `effectiveStatus` so the same
/// rename-with-mods → "modified" promotion that the
/// file card badge applies is mirrored here, keeping
/// both views in lockstep.
private func tocStatusIcon(
    for file: GdiffFile
) -> (String, String) {
    switch effectiveStatus(for: file) {
    case "added":
        return ("toc-status-added", "A")
    case "deleted":
        return ("toc-status-deleted", "D")
    case "renamed":
        return ("toc-status-renamed", "R")
    case "binary":
        return ("toc-status-binary", "B")
    default:
        return ("toc-status-modified", "M")
    }
}

/// Chevron-down SVG used on folder rows. CSS
/// rotates to -90° when the parent `<li>` has the
/// `.collapsed` class, so we only ship one glyph.
private func tocChevronSVG() -> String {
    let path = ""
        + "M12.78 5.22a.749.749 0 010 1.06l-4.25"
        + " 4.25a.749.749 0 01-1.06 0L3.22 6.28a.749"
        + ".749 0 111.06-1.06L8 9.939l3.72-3.719a"
        + ".749.749 0 011.06 0z"
    return "<svg class=\"toc-chevron\""
        + " viewBox=\"0 0 16 16\" width=\"12\""
        + " height=\"12\" fill=\"currentColor\""
        + " aria-hidden=\"true\">"
        + "<path d=\"\(path)\"/></svg>"
}

// MARK: - Utility

/// CSS class + human label for a file's status
/// badge. Renamed files without any content changes
/// show as "renamed" (useful signal: just moved —
/// nothing to review inside); renamed files WITH
/// content changes show as "modified" instead, since
/// the content diff is what the reviewer actually
/// cares about and an "R" badge would suggest the
/// opposite. The old→new path is still visible
/// inside the file card body.
private func statusBadge(
    for file: GdiffFile
) -> (String, String) {
    switch effectiveStatus(for: file) {
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

/// Resolves the status we actually want to show the
/// user — promoting a renamed-with-content-change
/// file to "modified" so the TOC badge and the file
/// card header tell the same story.
private func effectiveStatus(
    for file: GdiffFile
) -> String {
    if file.status == "renamed"
        && !file.hunks.isEmpty
    {
        return "modified"
    }
    return file.status
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

    // Tooltip matches any element with a data-tooltip
    // attribute — currently the collapse chevron and
    // the copy-path button, but any future header
    // affordance gets the same pill for free by
    // stamping the attribute.
    document.addEventListener('mouseover', function(e) {
        var btn = e.target.closest('[data-tooltip]');
        if (!btn || btn === hoverBtn) return;
        hoverBtn = btn;
        showTooltip(btn);
    });

    document.addEventListener('mouseout', function(e) {
        if (!hoverBtn) return;
        var btn = e.target.closest('[data-tooltip]');
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

    // Shared helper used by both the chevron click
    // path and the Viewed checkbox change path. Sets
    // the file-card's collapsed state, updates the
    // chevron's label + aria, repositions annotations,
    // and optionally hides annotation cards anchored
    // to this file.
    function applyCollapsedState(card, collapsed) {
        card.classList.toggle('collapsed', collapsed);

        var btn = card.querySelector(
            '.file-collapse-toggle');
        if (btn) {
            var label = collapsed
                ? 'Expand file' : 'Collapse file';
            btn.setAttribute('data-tooltip', label);
            btn.setAttribute('aria-label', label);
            btn.setAttribute('aria-expanded',
                collapsed ? 'false' : 'true');
        }

        var filePath = card.getAttribute(
            'data-file-path');
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

        if (typeof AnnotationManager !== 'undefined' &&
            typeof AnnotationManager.syncAllPositions
                === 'function') {
            AnnotationManager.syncAllPositions();
        }
    }

    // Viewed checkbox change — mirror the DOM state
    // into collapsed-ness and notify Swift for
    // persistence. Check collapses; uncheck expands.
    //
    // If the user checks Viewed while scrolled deep
    // in the file (sticky header is pinned at viewport
    // top), collapsing normally yanks the body out
    // from under them and drops the collapsed header
    // far above the viewport — they end up looking at
    // the next file with no visual tie to what they
    // just marked. Snap scroll to the card's top in
    // document coords so the collapsed header takes
    // the viewport-top slot its sticky pin occupied,
    // matching the "I'm done, next file please" intent
    // of the Viewed action. Chevron collapse doesn't
    // do this because it's a general show/hide
    // affordance without that semantic commitment.
    document.addEventListener('change', function(e) {
        var cb = e.target.closest(
            '.file-viewed input[type="checkbox"]');
        if (!cb) return;
        var card = cb.closest('.file-card');
        if (!card) return;
        var isViewed = cb.checked;

        var scrollAnchor = null;
        if (isViewed) {
            var rect = card.getBoundingClientRect();
            // Sticky is active when the card straddles
            // viewport top — its natural top is above 0
            // (user scrolled past it) while its bottom
            // is still below 0 (card hasn't fully
            // scrolled off).
            if (rect.top < 0 && rect.bottom > 0) {
                scrollAnchor = rect.top
                    + window.scrollY;
            }
        }

        applyCollapsedState(card, isViewed);

        if (scrollAnchor !== null) {
            window.scrollTo(
                window.scrollX, scrollAnchor);
        }

        var filePath = card.getAttribute(
            'data-file-path');
        if (filePath && window.webkit
            && window.webkit.messageHandlers
            && window.webkit.messageHandlers.annotation) {
            window.webkit.messageHandlers.annotation
                .postMessage({
                    action: 'setViewed',
                    filePath: filePath,
                    isViewed: isViewed
                });
        }
    });

    document.addEventListener('click', function(e) {
        var btn = e.target.closest('.file-collapse-toggle');
        if (!btn) return;
        var card = btn.closest('.file-card');
        if (!card) return;

        var collapsed = !card.classList.contains('collapsed');
        applyCollapsedState(card, collapsed);

        // Refresh the hover tooltip inline — the mouse
        // is still on the button but its label and Y
        // coord (after the card's height change) just
        // updated. Everything else the click used to
        // do is now inside applyCollapsedState().
        if (hoverBtn === btn) {
            positionTooltip(btn);
        }
    });

    // Copy-file-path handler — reads the card's
    // data-file-path, writes to the clipboard, and
    // flashes visual feedback (check icon + "Copied!"
    // tooltip for 1.5s). Icon swap done via SVG
    // innerHTML replacement so we don't pay the cost
    // of maintaining both glyphs in the DOM
    // permanently. Reverts to the original copy icon
    // + tooltip text after the timeout.
    var COPY_ICON_SVG =
        '<svg class="copy-icon" width="12"'
        + ' height="12" viewBox="0 0 16 16"'
        + ' aria-hidden="true">'
        + '<path fill="currentColor"'
        + ' d="M0 6.75C0 5.784.784 5 1.75 5h1.5a.75'
        + '.75 0 0 1 0 1.5h-1.5a.25.25 0 0 0-.25.25v7'
        + '.5c0 .138.112.25.25.25h7.5a.25.25 0 0 0 .'
        + '25-.25v-1.5a.75.75 0 0 1 1.5 0v1.5A1.75 1'
        + '.75 0 0 1 9.25 16h-7.5A1.75 1.75 0 0 1 0 '
        + '14.25Z"/>'
        + '<path fill="currentColor"'
        + ' d="M5 1.75C5 .784 5.784 0 6.75 0h7.5C15'
        + '.216 0 16 .784 16 1.75v7.5A1.75 1.75 0 0 '
        + '1 14.25 11h-7.5A1.75 1.75 0 0 1 5 9.25Zm1'
        + '.75-.25a.25.25 0 0 0-.25.25v7.5c0 .138.11'
        + '2.25.25.25h7.5a.25.25 0 0 0 .25-.25v-7.5a'
        + '.25.25 0 0 0-.25-.25Z"/>'
        + '</svg>';
    var CHECK_ICON_SVG =
        '<svg class="copy-icon" width="12"'
        + ' height="12" viewBox="0 0 16 16"'
        + ' aria-hidden="true">'
        + '<path fill="currentColor"'
        + ' d="M13.78 4.22a.75.75 0 0 1 0 1.06l-7.25'
        + ' 7.25a.75.75 0 0 1-1.06 0L2.22 9.28a.751'
        + '.751 0 0 1 .018-1.042.751.751 0 0 1 1.04'
        + '2-.018L6 10.94l6.72-6.72a.75.75 0 0 1 1'
        + '.06 0Z"/>'
        + '</svg>';
    var COPY_DEFAULT_TOOLTIP = 'Copy file path to clipboard';

    function showCopiedFeedback(btn) {
        btn.classList.add('copied');
        btn.innerHTML = CHECK_ICON_SVG;
        btn.setAttribute('data-tooltip', 'Copied!');
        btn.setAttribute('aria-label', 'Copied!');
        if (hoverBtn === btn) positionTooltip(btn);

        if (btn._copyResetTimer) {
            clearTimeout(btn._copyResetTimer);
        }
        btn._copyResetTimer = setTimeout(function() {
            btn.classList.remove('copied');
            btn.innerHTML = COPY_ICON_SVG;
            btn.setAttribute('data-tooltip',
                COPY_DEFAULT_TOOLTIP);
            btn.setAttribute('aria-label',
                COPY_DEFAULT_TOOLTIP);
            if (hoverBtn === btn) positionTooltip(btn);
            btn._copyResetTimer = null;
        }, 1500);
    }

    function copyTextLegacy(text) {
        var ta = document.createElement('textarea');
        ta.value = text;
        ta.style.position = 'fixed';
        ta.style.top = '-1000px';
        ta.style.left = '-1000px';
        document.body.appendChild(ta);
        ta.select();
        var ok = false;
        try { ok = document.execCommand('copy'); }
        catch (err) { ok = false; }
        document.body.removeChild(ta);
        return ok;
    }

    document.addEventListener('click', function(e) {
        var btn = e.target.closest('.file-copy-path');
        if (!btn) return;
        var card = btn.closest('.file-card');
        if (!card) return;
        var path = card.getAttribute('data-file-path');
        if (!path) return;

        // Try modern clipboard API first; fall back to
        // execCommand for environments where it's
        // unavailable. Visual feedback fires on success
        // from either path.
        if (navigator.clipboard
            && navigator.clipboard.writeText) {
            navigator.clipboard.writeText(path).then(
                function() { showCopiedFeedback(btn); },
                function() {
                    if (copyTextLegacy(path)) {
                        showCopiedFeedback(btn);
                    }
                }
            );
        } else if (copyTextLegacy(path)) {
            showCopiedFeedback(btn);
        }
    });
})();
"""

/// JS for the TOC sidebar: folder chevron toggle and
/// click-to-scroll on file rows. All the tree data
/// is static in the rendered HTML — this script just
/// wires up the two interactions without needing any
/// model reflection back into Swift.
///
/// The file click-to-scroll deliberately does NOT
/// force-expand a collapsed file card (the user hit
/// the "Viewed" checkbox for a reason) — it scrolls
/// to the card header and leaves it up to the user
/// to click the chevron if they want to re-expand.
private let tocNavJS: String = """
(function() {
    document.querySelectorAll('.toc-folder-label')
        .forEach(function(btn) {
            btn.addEventListener('click', function(e) {
                e.preventDefault();
                var folder = btn.closest('.toc-folder');
                if (!folder) return;
                folder.classList.toggle('collapsed');
                var expanded = !folder.classList
                    .contains('collapsed');
                btn.setAttribute(
                    'aria-expanded', String(expanded)
                );
            });
        });

    document.querySelectorAll('.toc-file-label')
        .forEach(function(btn) {
            btn.addEventListener('click', function(e) {
                e.preventDefault();
                var id = btn.getAttribute('data-target');
                if (!id) return;
                var card = document.getElementById(id);
                if (!card) return;
                card.scrollIntoView({
                    behavior: 'smooth',
                    block: 'start'
                });
            });
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
