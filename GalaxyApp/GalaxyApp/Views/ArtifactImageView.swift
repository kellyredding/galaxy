import SwiftUI
import WebKit

/// Renders image artifacts (PNG, JPG, GIF, SVG, WebP) in
/// a WKWebView for consistent zoom support via
/// SilentFunctionKeyWebView.
struct ArtifactImageView: NSViewRepresentable {
    let filePath: String
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

        let html = buildImageHTML(
            filePath: filePath,
            isDark: isDark
        )
        webView.loadHTMLString(
            html,
            baseURL: URL(
                fileURLWithPath:
                    (filePath as NSString)
                    .deletingLastPathComponent
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

            let html = buildImageHTML(
                filePath: filePath,
                isDark: isDark
            )
            webView.loadHTMLString(
                html,
                baseURL: URL(
                    fileURLWithPath:
                        (filePath as NSString)
                        .deletingLastPathComponent
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

// MARK: - HTML Generation

private func buildImageHTML(
    filePath: String,
    isDark: Bool
) -> String {
    let bgColor = isDark ? "#0d1117" : "#ffffff"
    let filename = (filePath as NSString)
        .lastPathComponent
    let ext = (filename as NSString)
        .pathExtension.lowercased()

    // For SVG, embed inline if possible
    let isSVG = ext == "svg"
    let svgContent: String?
    if isSVG,
       let data = FileManager.default
           .contents(atPath: filePath),
       let str = String(data: data, encoding: .utf8)
    {
        svgContent = str
    } else {
        svgContent = nil
    }

    let imageElement: String
    if let svg = svgContent {
        // Inline SVG for best rendering
        imageElement = """
        <div class="svg-container">\(svg)</div>
        """
    } else {
        // Use file:// URL for raster images
        imageElement = """
        <img src="file://\(filePath)"
             alt="\(filename)" />
        """
    }

    // Checkerboard pattern for transparent images
    let checkerColor = isDark ? "#1a1a2e" : "#f0f0f0"

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
        height: 100%;
        -webkit-font-smoothing: antialiased;
    }
    .image-container {
        display: flex;
        justify-content: center;
        align-items: center;
        min-height: 100vh;
        padding: 24px;
        background-image: linear-gradient(
            45deg, \(checkerColor) 25%, transparent 25%
        ), linear-gradient(
            -45deg, \(checkerColor) 25%, transparent 25%
        ), linear-gradient(
            45deg, transparent 75%, \(checkerColor) 75%
        ), linear-gradient(
            -45deg, transparent 75%, \(checkerColor) 75%
        );
        background-size: 20px 20px;
        background-position: 0 0, 0 10px,
            10px -10px, -10px 0px;
    }
    img {
        max-width: 100%;
        max-height: 90vh;
        object-fit: contain;
        border-radius: 4px;
    }
    .svg-container {
        max-width: 100%;
        display: flex;
        justify-content: center;
    }
    .svg-container svg {
        max-width: 100%;
        max-height: 90vh;
    }
    </style>
    </head>
    <body>
    <div class="image-container">
    \(imageElement)
    </div>
    </body>
    </html>
    """
}
