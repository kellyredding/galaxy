import SwiftUI
import WebKit

/// Renders standalone .mmd/.mermaid files using the
/// vendored mermaid.js. Supports zoom via the shared
/// SilentFunctionKeyWebView and annotation via the
/// generalized AnnotationManager JS.
struct ArtifactMermaidView: NSViewRepresentable {
    let content: String
    let isDark: Bool
    let annotations: [ArtifactAnnotation]
    let annotationHTMLMap: [Int32: String]
    let itemLabel: String
    var onAnnotationMessage:
        ((AnnotationMessage) -> Void)?
    @Binding var webViewRef: WKWebView?

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
        webView.setValue(false, forKey: "drawsBackground")
        webView.isInspectable = true
        webView.navigationDelegate =
            context.coordinator

        webView.wantsLayer = true
        webView.layer?.backgroundColor =
            isDark
            ? NSColor.black.cgColor
            : NSColor.white.cgColor

        let initJS = buildAnnotationInitJS(
            anchorType: "whole",
            blockSelector: "",
            lineAttr: "",
            refPrefix: "",
            itemLabel: itemLabel,
            annotations: annotations,
            htmlMap: annotationHTMLMap
        )
        context.coordinator.pendingInitJS = initJS
        context.coordinator.onAnnotationMessage =
            onAnnotationMessage

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
        context.coordinator.onAnnotationMessage =
            onAnnotationMessage

        if context.coordinator.lastIsDark != isDark {
            context.coordinator.lastIsDark = isDark

            webView.wantsLayer = true
            webView.layer?.backgroundColor =
                isDark
                ? NSColor.black.cgColor
                : NSColor.white.cgColor

            let initJS = buildAnnotationInitJS(
                anchorType: "whole",
                blockSelector: "",
                lineAttr: "",
                refPrefix: "",
                itemLabel: itemLabel,
                annotations: annotations,
                htmlMap: annotationHTMLMap
            )
            context.coordinator.pendingInitJS = initJS

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

    func makeCoordinator() -> AnnotationCoordinator {
        AnnotationCoordinator(isDark: isDark)
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
    :root {
        \(annotationCSSVars(isDark: isDark))
    }
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
    \(annotationCSS)
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
    <script>\(clipboardCopyJS)</script>
    <script>\(annotationManagerJS)</script>
    <script>\(emojiDataJS)</script>
    <script>\(emojiAutocompleteJS)</script>
    </body>
    </html>
    """
}
