import SwiftUI
import WebKit

/// Renders source code or plain text with line numbers and
/// syntax highlighting in a WKWebView. Uses the same vendored
/// highlight.js and theme CSS as MarkdownReaderView.
struct ArtifactSourceView: NSViewRepresentable {
    let content: String
    let language: String?
    let isDark: Bool
    @Binding var webViewRef: WKWebView?

    func makeNSView(
        context: Context
    ) -> SilentFunctionKeyWebView {
        let config = WKWebViewConfiguration()
        let webView = SilentFunctionKeyWebView(
            frame: .zero, configuration: config
        )
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate =
            context.coordinator

        // Transparent webview over opaque background
        let container = webView
        container.wantsLayer = true
        container.layer?.backgroundColor =
            isDark
            ? NSColor.black.cgColor
            : NSColor.white.cgColor

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
        // Theme change: reload with new HTML
        if context.coordinator.lastIsDark != isDark {
            context.coordinator.lastIsDark = isDark

            webView.wantsLayer = true
            webView.layer?.backgroundColor =
                isDark
                ? NSColor.black.cgColor
                : NSColor.white.cgColor

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
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isDark: isDark)
    }

    class Coordinator: NSObject,
        WKNavigationDelegate
    {
        var lastIsDark: Bool

        init(isDark: Bool) {
            self.lastIsDark = isDark
        }

        // Allow the initial HTML load; block link
        // navigation so galaxy:// baseURL doesn't
        // trigger macOS URL scheme handling.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor nav: WKNavigationAction,
            decisionHandler: @escaping
                (WKNavigationActionPolicy) -> Void
        ) {
            if nav.navigationType == .linkActivated {
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
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

    let themeClass = isDark ? "dark" : "light"
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
            "<tr class=\"code-line\" data-line=\"\(lineNum)\">"
            + "<td class=\"line-num\">\(lineNum)</td>"
            + "<td class=\"line-content\">"
            + "\(escapedLine.isEmpty ? " " : escapedLine)"
            + "</td></tr>\n"
    }

    let langClass =
        language != nil
        ? "language-\(language!)"
        : "nohighlight"

    return """
    <!DOCTYPE html>
    <html class="\(themeClass)">
    <head>
    <meta charset="utf-8">
    <meta name="viewport"
          content="width=device-width, initial-scale=1">
    <title>Galaxy Artifact Reader</title>
    <style>
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
        overflow: hidden;
        height: 100%;
    }
    .source-container {
        width: 100%;
        height: 100%;
        overflow: auto;
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
        // Highlight each line-content cell individually
        document.querySelectorAll('.line-content')
            .forEach(function(el) {
                hljs.highlightElement(el);
            });
    }
    </script>
    </body>
    </html>
    """
}
