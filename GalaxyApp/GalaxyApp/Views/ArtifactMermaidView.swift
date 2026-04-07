import SwiftUI
import WebKit

/// Renders standalone .mmd/.mermaid files using the
/// vendored mermaid.js. Supports zoom via the shared
/// SilentFunctionKeyWebView.
struct ArtifactMermaidView: NSViewRepresentable {
    let content: String
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

        webView.wantsLayer = true
        webView.layer?.backgroundColor =
            isDark
            ? NSColor.black.cgColor
            : NSColor.white.cgColor

        let html = buildMermaidHTML(
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

            let html = buildMermaidHTML(
                content: content,
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

// MARK: - Mermaid JS (shared with MarkdownReaderView)

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

// MARK: - HTML Generation

private func buildMermaidHTML(
    content: String,
    isDark: Bool
) -> String {
    let bgColor = isDark ? "#0d1117" : "#ffffff"
    let textColor = isDark ? "#e6edf3" : "#1f2328"
    let theme = isDark ? "dark" : "default"

    let escaped = content
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")

    return """
    <!DOCTYPE html>
    <html>
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
        font-family: -apple-system, BlinkMacSystemFont,
            'SF Pro Text', 'Helvetica Neue', sans-serif;
        -webkit-font-smoothing: antialiased;
    }
    .mermaid-container {
        display: flex;
        justify-content: center;
        padding: 32px 16px;
        width: 100%;
    }
    .mermaid {
        width: 100%;
    }
    .mermaid svg {
        width: 100%;
        height: auto;
    }
    </style>
    </head>
    <body>
    <div class="mermaid-container">
    <pre class="mermaid">\(escaped)</pre>
    </div>
    <script>\(mermaidJS)</script>
    <script>
    if (typeof mermaid !== 'undefined') {
        mermaid.initialize({
            startOnLoad: false,
            theme: '\(theme)',
            securityLevel: 'loose',
        });
        mermaid.run();
    }
    </script>
    </body>
    </html>
    """
}
