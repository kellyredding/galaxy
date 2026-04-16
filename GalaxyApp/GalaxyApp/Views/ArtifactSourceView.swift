import SwiftUI
import WebKit

/// Renders source code or plain text with line numbers and
/// syntax highlighting in a WKWebView. Uses the same vendored
/// highlight.js and theme CSS as MarkdownReaderView.
/// Supports line_range annotations via the shared
/// AnnotationManager JS.
struct ArtifactSourceView: NSViewRepresentable {
    let content: String
    let language: String?
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

        // Build init JS for after page load
        let activeAnns = annotations.filter {
            !$0.stale
                && $0.anchorData.type == .lineRange
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

        let html = buildSourceHTML(
            content: content,
            language: language,
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

            // Save form state before reload
            webView.evaluateJavaScript(
                "typeof AnnotationManager !== 'undefined'"
                + " ? JSON.stringify("
                + "AnnotationManager.getFormState())"
                + " : null"
            ) { result, _ in
                let activeAnns = annotations.filter {
                    !$0.stale
                        && $0.anchorData.type
                            == .lineRange
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

                let html = buildSourceHTML(
                    content: content,
                    language: language,
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

private func buildSourceHTML(
    content: String,
    language: String?,
    isDark: Bool
) -> String {
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

    // Build line-numbered code block
    let lines = content.components(separatedBy: "\n")
    var lineHTML = ""
    for (i, line) in lines.enumerated() {
        let lineNum = i + 1
        let escapedLine = line
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        lineHTML +=
            "<tr class=\"code-line\""
            + " data-line=\"\(lineNum)\">"
            + "<td class=\"line-num\">\(lineNum)</td>"
            + "<td class=\"line-content\">"
            + "\(escapedLine.isEmpty ? " " : escapedLine)"
            + "</td></tr>\n"
    }

    let langClass =
        language != nil
        ? "language-\(language!)"
        : "nohighlight"

    let cssVars = annotationCSSVars(isDark: isDark)

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
    .source-container {
        width: 100%;
        overflow-x: auto;
    }
    table.source-table {
        border-collapse: collapse;
        width: max-content;
        min-width: 100%;
    }
    .code-line td {
        padding: 0 0;
        vertical-align: top;
        white-space: pre;
    }
    .line-num {
        width: 4em;
        min-width: 4em;
        max-width: 4em;
        text-align: right;
        padding-right: 12px !important;
        padding-left: 8px !important;
        color: \(lineNumColor);
        background: \(gutterBg);
        user-select: none;
        -webkit-user-select: none;
        border-right: 1px solid
            \(isDark ? "#21262d" : "#d0d7de");
        position: sticky;
        left: 0;
        z-index: 1;
    }
    .line-content {
        padding-left: 12px !important;
        padding-right: 16px !important;
    }
    /* Override hljs background — we handle it */
    .hljs { background: transparent !important; }
    /* Annotation highlight adaption for table rows */
    .code-line.annotation-highlight td {
        background-color: rgba(88, 166, 255, 0.12);
    }
    .code-line.annotation-highlight .line-num {
        border-left: 3px solid
            rgba(88, 166, 255, 0.6);
        padding-left: 5px !important;
    }
    .code-line.annotation-expanded-highlight td {
        background-color:
            var(--annotation-active-block-bg);
    }
    .code-line.annotation-expanded-highlight .line-num {
        border-left: 3px solid
            var(--annotation-active-block-border);
        padding-left: 5px !important;
    }
    \(annotationCSS)
    \(themeCSS)
    </style>
    </head>
    <body>
    <div class="source-container">
    <table class="source-table">
    <tbody class="\(langClass)">
    \(lineHTML)
    </tbody>
    </table>
    </div>
    <script>\(hjsContent)</script>
    <script>
    if (typeof hljs !== 'undefined') {
        document.querySelectorAll('.line-content')
            .forEach(function(el) {
                hljs.highlightElement(el);
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
