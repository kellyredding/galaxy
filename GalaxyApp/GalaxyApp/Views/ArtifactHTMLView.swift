import SwiftUI
import WebKit

/// Renders HTML artifacts in a sandboxed WKWebView.
/// External links open in the default browser.
struct ArtifactHTMLView: NSViewRepresentable {
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
            if nav.navigationType == .linkActivated,
               let url = nav.request.url,
               url.scheme == "http"
                   || url.scheme == "https"
            {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}

// MARK: - HTML Wrapping

/// If the HTML already has a full document structure,
/// render it as-is. Otherwise, wrap it in a minimal
/// themed shell.
private func wrapHTML(
    content: String,
    isDark: Bool
) -> String {
    let lower = content.lowercased()

    // If it already has <html> or <!doctype>, render
    // as-is (the author controls the full page).
    if lower.contains("<html")
        || lower.contains("<!doctype")
    {
        return content
    }

    // Otherwise wrap in a themed shell
    let bgColor = isDark ? "#0d1117" : "#ffffff"
    let textColor = isDark ? "#e6edf3" : "#1f2328"

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
        font-size: 14px;
        line-height: 1.5;
        -webkit-font-smoothing: antialiased;
    }
    .html-container {
        padding: 16px;
    }
    img { max-width: 100%; height: auto; }
    a { color: \(isDark ? "#58a6ff" : "#0969da"); }
    </style>
    </head>
    <body>
    <div class="html-container">
    \(content)
    </div>
    </body>
    </html>
    """
}
