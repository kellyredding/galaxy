import SwiftUI
import WebKit
import Galactic

/// How this reader anchors annotations into its markup.
let imageAnchoring = ReaderAnchoring.whole

/// Renders image artifacts (PNG, JPG, GIF, SVG, WebP) in
/// a WKWebView for consistent zoom support via
/// ReaderWebView and annotation via the
/// generalized AnnotationManager JS.
struct ArtifactImageView: NSViewRepresentable {
    let filePath: String
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
            anchoring: imageAnchoring,
            itemLabel: itemLabel,
            annotations: annotations,
            htmlMap: annotationHTMLMap
        )
        context.coordinator.pendingInitJS = initJS
        context.coordinator.onAnnotationMessage =
            onAnnotationMessage

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
                anchoring: imageAnchoring,
                itemLabel: itemLabel,
                annotations: annotations,
                htmlMap: annotationHTMLMap
            )
            context.coordinator.pendingInitJS = initJS

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

    func makeCoordinator() -> AnnotationCoordinator {
        AnnotationCoordinator(isDark: isDark)
    }
}

// MARK: - HTML Generation

/// Map a raster image extension to its MIME type for the
/// inline data URI. SVG is handled separately (inlined as
/// markup), so it is intentionally absent here.
private func rasterMIMEType(
    forExtension ext: String
) -> String {
    switch ext {
    case "png": return "image/png"
    case "jpg", "jpeg": return "image/jpeg"
    case "gif": return "image/gif"
    case "webp": return "image/webp"
    default: return "application/octet-stream"
    }
}

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
    } else if let data = FileManager.default
        .contents(atPath: filePath)
    {
        // Inline raster bytes as a base64 data URI. A
        // WKWebView loaded via loadHTMLString is not
        // granted file:// subresource read access, so a
        // <img src="file://…"> silently fails to load and
        // renders the broken-image glyph. Embedding the
        // bytes sidesteps the WebKit sandbox entirely.
        let mime = rasterMIMEType(forExtension: ext)
        let base64 = data.base64EncodedString()
        imageElement = """
        <img src="data:\(mime);base64,\(base64)"
             alt="\(filename)" />
        """
    } else {
        // File unreadable (moved/deleted/permissions).
        imageElement = """
        <div class="image-error">
        Could not read image file:<br>\(filename)
        </div>
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
    :root {
        \(annotationCSSVars(isDark: isDark))
    }
    * { margin: 0; padding: 0; box-sizing: border-box; }
    html, body {
        background: \(bgColor);
        -webkit-font-smoothing: antialiased;
    }
    .image-container {
        display: flex;
        justify-content: center;
        align-items: center;
        min-height: 50vh;
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
    .image-error {
        color: \(isDark ? "#e6edf3" : "#1f2328");
        font-family: -apple-system, BlinkMacSystemFont,
            "Segoe UI", Helvetica, Arial, sans-serif;
        font-size: 14px;
        text-align: center;
        line-height: 1.6;
        opacity: 0.7;
    }
    \(annotationCSS)
    </style>
    </head>
    <body>
    <div class="image-container">
    \(imageElement)
    </div>
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
