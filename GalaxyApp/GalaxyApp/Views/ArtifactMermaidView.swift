import SwiftUI
import WebKit
import Galactic

/// How this reader anchors annotations into its markup.
let mermaidAnchoring = ReaderAnchoring.whole

/// Renders standalone .mmd/.mermaid files using the
/// vendored mermaid.js. Supports zoom via the shared
/// ReaderWebView and annotation via the
/// generalized AnnotationManager JS.
struct ArtifactMermaidView: NSViewRepresentable {
    let content: String
    let isDark: Bool
    let annotations: [any ReaderAnnotation]
    let annotationHTMLMap: [Int32: String]
    let itemLabel: String
    var onAnnotationMessage:
        ((AnnotationMessage) -> Void)?
    @Binding var webViewRef: WKWebView?

    func makeNSView(
        context: Context
    ) -> ReaderWebView {
        let config = WKWebViewConfiguration()
        config.installGalaxyFindUserScript()
        config.userContentController.add(
            context.coordinator, name: "annotation"
        )
        let webView = ReaderWebView(
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
            anchoring: mermaidAnchoring,
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
        _ webView: ReaderWebView,
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
                anchoring: mermaidAnchoring,
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

private let mermaidJS = ReaderAssets.mermaidJS

// MARK: - HTML Generation

private func buildMermaidHTML(
    content: String,
    isDark: Bool
) -> String {
    let bgColor = isDark ? "#0d1117" : "#ffffff"
    let textColor = isDark ? "#e6edf3" : "#1f2328"
    let theme = isDark ? "dark" : "default"

    let escaped = HTMLEscape.text(content)

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
    <script>\(cardTextJS)</script>
    <script>\(clipboardCopyJS)</script>
    <script>\(textEntryJS)</script>
    <script>\(suggestionInsertJS)</script>
    <script>\(annotationManagerJS)</script>
    <script>\(emojiDataJS)</script>
    <script>\(emojiAutocompleteJS)</script>
    </body>
    </html>
    """
}
