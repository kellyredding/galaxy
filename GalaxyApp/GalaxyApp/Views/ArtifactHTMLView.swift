import SwiftUI
import WebKit
import Galactic

/// Renders HTML artifacts in a sandboxed WKWebView.
/// External links open in the default browser.
/// Supports block_range annotations via the shared
/// AnnotationManager JS with a DOM-walk block-index
/// pass after page load.
struct ArtifactHTMLView: NSViewRepresentable {
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
        config.installGalaxyFindUserScript()
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
            !$0.stale
                && AnnotationScope.blockRange
                    .accepts($0.anchorData.type)
        }
        // DOM-walk runs first, then annotation init
        let domWalkJS = blockIndexDOMWalkJS
        let initJS = buildAnnotationInitJS(
            anchorType: "block_range",
            blockSelector: ".annotatable-block",
            lineAttr: "data-block-index",
            refPrefix: "Block",
            itemLabel: itemLabel,
            annotations: activeAnns,
            htmlMap: annotationHTMLMap
        )
        context.coordinator.pendingInitJS =
            domWalkJS + "; " + initJS
        context.coordinator.onAnnotationMessage =
            onAnnotationMessage

        let html = wrapHTML(
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
                    !$0.stale
                        && AnnotationScope.blockRange
                            .accepts($0.anchorData.type)
                }
                let domWalkJS = blockIndexDOMWalkJS
                var initJS = buildAnnotationInitJS(
                    anchorType: "block_range",
                    blockSelector: ".annotatable-block",
                    lineAttr: "data-block-index",
                    refPrefix: "Block",
                    itemLabel: itemLabel,
                    annotations: activeAnns,
                    htmlMap: annotationHTMLMap
                )
                if let stateJSON = result as? String {
                    initJS += "; AnnotationManager"
                        + ".restoreFormState("
                        + stateJSON + ")"
                }
                context.coordinator.pendingInitJS =
                    domWalkJS + "; " + initJS

                let html = wrapHTML(
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

// MARK: - DOM Walk Block Index JS

/// JS that walks the DOM and assigns
/// data-block-index + annotatable-block class to
/// block-level elements. Must run after page load,
/// before AnnotationManager.initialize().
// js-validate
private let blockIndexDOMWalkJS: String = """
(function() {
    // Leaf selectors — the actual annotatable
    // units. Note: <pre> is NOT in this list;
    // it gets split into per-line divs below.
    var leafSel = 'p,h1,h2,h3,h4,h5,h6,li,tr,' +
        'figcaption,dt,dd';
    var index = 1;

    function tagBlock(el) {
        el.setAttribute('data-block-index', index);
        el.classList.add('annotatable-block');
        index++;
    }

    document.querySelectorAll(leafSel)
        .forEach(function(el) {
            if (el.closest('[data-block-index]'))
                return;
            tagBlock(el);
        });

    // Split <pre> blocks into per-line divs so
    // each line is independently annotatable.
    document.querySelectorAll('pre')
        .forEach(function(pre) {
            if (pre.closest('[data-block-index]'))
                return;
            var code = pre.querySelector('code');
            var src = code
                ? code.textContent
                : pre.textContent;
            var lines = src.split('\\n');
            // Drop trailing empty line from
            // trailing newline
            if (lines.length > 0
                && lines[lines.length - 1] === '')
            {
                lines.pop();
            }
            // Clear existing content
            pre.innerHTML = '';
            pre.classList.add('code-block-wrapper');
            lines.forEach(function(line) {
                var div = document.createElement(
                    'div'
                );
                div.className =
                    'annotatable-block code-line';
                var codeEl = document.createElement(
                    'code'
                );
                codeEl.textContent =
                    line || '\\u00A0';
                div.appendChild(codeEl);
                tagBlock(div);
                pre.appendChild(div);
            });
        });
})()
"""

// MARK: - HTML Wrapping

// MARK: - Theme-Aware Base Stylesheet

/// Provides sensible dark/light defaults for common
/// HTML elements so artifacts don't need to be
/// theme-aware. Uses CSS vars from annotationCSSVars
/// plus additional vars for borders, links, and HRs.
/// Injected AFTER artifact styles so cascade order
/// wins for equal-specificity selectors.
private func htmlBaseCSS(isDark: Bool) -> String {
    let blockquoteBorder = isDark
        ? "#555" : "#ddd"
    let tableBorder = isDark
        ? "#444" : "#ddd"
    let linkColor = isDark
        ? "#58a6ff" : "#0969da"
    let hrColor = isDark
        ? "#444" : "#d0d7de"

    return """
    /* Galaxy theme-aware base styles */
    :root {
        --blockquote-border: \(blockquoteBorder);
        --table-border: \(tableBorder);
        --link-color: \(linkColor);
        --hr-color: \(hrColor);
    }
    html, body {
        background: var(--bg);
        color: var(--fg);
        font-family: -apple-system, BlinkMacSystemFont,
            "Segoe UI", Helvetica, Arial, sans-serif;
        font-size: 14px;
        line-height: 1.6;
        -webkit-font-smoothing: antialiased;
    }
    h1, h2, h3, h4, h5, h6 {
        margin-top: 24px;
        margin-bottom: 16px;
        font-weight: 600;
        line-height: 1.25;
        color: var(--fg);
    }
    h1 {
        font-size: 2em;
        padding-bottom: 0.3em;
        border-bottom: 1px solid var(--hr-color);
    }
    h2 {
        font-size: 1.5em;
        padding-bottom: 0.3em;
        border-bottom: 1px solid var(--hr-color);
    }
    h3 { font-size: 1.25em; }
    h4 { font-size: 1em; }
    h5 { font-size: 0.875em; }
    h6 {
        font-size: 0.85em;
        color: var(--blockquote-fg);
    }
    p { margin-top: 0; margin-bottom: 16px; }
    a {
        color: var(--link-color);
        text-decoration: none;
    }
    a:hover { text-decoration: underline; }
    code {
        font-family: "SF Mono", "Menlo", "Monaco",
            "Courier New", monospace;
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
        border-left: 0.25em solid
            var(--blockquote-border);
    }
    ul, ol {
        margin-top: 0;
        margin-bottom: 16px;
        padding-left: 2em;
    }
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
    img { max-width: 100%; height: auto; }
    """
}

/// If the HTML already has a full document structure,
/// inject our annotation infrastructure. Otherwise,
/// wrap it in a minimal themed shell.
private func wrapHTML(
    content: String,
    isDark: Bool
) -> String {
    let bgColor = isDark ? "#0d1117" : "#ffffff"
    let textColor = isDark ? "#e6edf3" : "#1f2328"
    let cssVars = annotationCSSVars(isDark: isDark)

    let lower = content.lowercased()

    // If it already has <html> or <!doctype>, inject
    // our scripts into the existing document.
    if lower.contains("<html")
        || lower.contains("<!doctype")
    {
        // Inject CSS vars and annotation styles before
        // </head>, and scripts before </body>
        var html = content

        let baseCSS = htmlBaseCSS(isDark: isDark)
        let styleBlock = """
        <style>
        :root { \(cssVars) }
        \(baseCSS)
        /* Code block line-level annotation support */
        .code-block-wrapper {
            margin: 0;
            padding: 16px;
        }
        .code-line {
            margin: 0;
            padding: 0;
            line-height: 1.45;
        }
        .code-line code {
            display: inline;
            background: none;
            padding: 0;
            border-radius: 0;
            white-space: pre;
        }
        .code-line.annotation-highlight {
            background-color:
                rgba(88, 166, 255, 0.12);
            border-left: 3px solid
                rgba(88, 166, 255, 0.6);
            padding-left: 8px;
            margin-left: -11px;
        }
        .code-line.annotation-expanded-highlight {
            background-color:
                var(--annotation-active-block-bg);
            border-left: 3px solid
                var(--annotation-active-block-border);
            padding-left: 8px;
            margin-left: -11px;
        }
        /* Annotation highlight for blocks */
        .annotatable-block.annotation-highlight {
            background-color:
                rgba(88, 166, 255, 0.12);
            border-left: 3px solid
                rgba(88, 166, 255, 0.6);
            padding-left: 8px;
            margin-left: -11px;
        }
        .annotatable-block.annotation-expanded-highlight {
            background-color:
                var(--annotation-active-block-bg);
            border-left: 3px solid
                var(--annotation-active-block-border);
            padding-left: 8px;
            margin-left: -11px;
        }
        tr.annotatable-block.annotation-highlight td,
        tr.annotatable-block.annotation-highlight th {
            background-color:
                rgba(88, 166, 255, 0.12);
        }
        tr.annotatable-block.annotation-highlight
            td:first-child,
        tr.annotatable-block.annotation-highlight
            th:first-child {
            border-left: 3px solid
                rgba(88, 166, 255, 0.6);
        }
        tr.annotatable-block.annotation-expanded-highlight td,
        tr.annotatable-block.annotation-expanded-highlight th {
            background-color:
                var(--annotation-active-block-bg);
        }
        tr.annotatable-block.annotation-expanded-highlight td:first-child,
        tr.annotatable-block.annotation-expanded-highlight th:first-child {
            border-left: 3px solid
                var(--annotation-active-block-border);
        }
        \(annotationCSS)
        </style>
        """
        let scriptBlock = """
        <script>\(clipboardCopyJS)</script>
        <script>\(textEntryJS)</script>
        <script>\(suggestionInsertJS)</script>
        <script>\(addNoteButtonJS)</script>
        <script>
        \(annotationManagerJS)
        </script>
        <script>\(emojiDataJS)</script>
        <script>\(emojiAutocompleteJS)</script>
        """

        if let headEnd = html.range(
            of: "</head>",
            options: .caseInsensitive
        ) {
            html.insert(
                contentsOf: styleBlock,
                at: headEnd.lowerBound
            )
        }
        if let bodyEnd = html.range(
            of: "</body>",
            options: .caseInsensitive
        ) {
            html.insert(
                contentsOf: scriptBlock,
                at: bodyEnd.lowerBound
            )
        }
        return html
    }

    // Otherwise wrap in a themed shell
    let baseCSS = htmlBaseCSS(isDark: isDark)
    return """
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8">
    <meta name="viewport"
          content="width=device-width, initial-scale=1">
    <title>Galaxy Artifact Reader</title>
    <style>
    :root {
        \(cssVars)
    }
    \(baseCSS)
    body { padding: 16px 24px; margin: 0; }
    /* Code block line-level annotation support */
    .code-block-wrapper {
        margin: 0;
        padding: 16px;
    }
    .code-line {
        margin: 0;
        padding: 0;
        line-height: 1.45;
    }
    .code-line code {
        display: inline;
        background: none;
        padding: 0;
        border-radius: 0;
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
        background-color:
            var(--annotation-active-block-bg);
        border-left: 3px solid
            var(--annotation-active-block-border);
        padding-left: 8px;
        margin-left: -11px;
    }
    /* Annotation highlight for blocks */
    .annotatable-block.annotation-highlight {
        background-color: rgba(88, 166, 255, 0.12);
        border-left: 3px solid
            rgba(88, 166, 255, 0.6);
        padding-left: 8px;
        margin-left: -11px;
    }
    .annotatable-block.annotation-expanded-highlight {
        background-color:
            var(--annotation-active-block-bg);
        border-left: 3px solid
            var(--annotation-active-block-border);
        padding-left: 8px;
        margin-left: -11px;
    }
    /* Table row annotation highlights */
    tr.annotatable-block.annotation-highlight td,
    tr.annotatable-block.annotation-highlight th {
        background-color: rgba(88, 166, 255, 0.12);
    }
    tr.annotatable-block.annotation-highlight
        td:first-child,
    tr.annotatable-block.annotation-highlight
        th:first-child {
        border-left: 3px solid
            rgba(88, 166, 255, 0.6);
    }
    tr.annotatable-block.annotation-expanded-highlight
        td,
    tr.annotatable-block.annotation-expanded-highlight
        th {
        background-color:
            var(--annotation-active-block-bg);
    }
    tr.annotatable-block.annotation-expanded-highlight
        td:first-child,
    tr.annotatable-block.annotation-expanded-highlight
        th:first-child {
        border-left: 3px solid
            var(--annotation-active-block-border);
    }
    \(annotationCSS)
    </style>
    </head>
    <body>
    \(content)
    <script>\(clipboardCopyJS)</script>
    <script>\(textEntryJS)</script>
    <script>\(suggestionInsertJS)</script>
    <script>\(addNoteButtonJS)</script>
    <script>
    \(annotationManagerJS)
    </script>
    <script>\(emojiDataJS)</script>
    <script>\(emojiAutocompleteJS)</script>
    </body>
    </html>
    """
}
