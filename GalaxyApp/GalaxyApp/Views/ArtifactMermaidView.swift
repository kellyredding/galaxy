import SwiftUI
import WebKit
import Galactic

/// How this reader anchors annotations into its markup.
let mermaidAnchoring = ReaderAnchoring.whole

/// Renders standalone .mmd/.mermaid files using the
/// vendored mermaid.js. Supports zoom via the shared
/// ReaderWebView and annotation via the
/// generalized AnnotationManager JS.
struct ArtifactMermaidView: View {
    let content: String
    let isDark: Bool
    let annotations: [any ReaderAnnotation]
    let annotationHTMLMap: [Int32: String]
    let itemLabel: String
    var onAnnotationMessage: ((AnnotationMessage) -> Void)?
    @Binding var webViewRef: WKWebView?

    var body: some View {
        ReaderHostView(
            isDark: isDark,
            reloadToken: isDark,
            document: {
                buildMermaidHTML(content: content, isDark: isDark)
            },
            annotationInitJS: { formState in
                buildAnnotationInitJS(
                    anchoring: mermaidAnchoring,
                    itemLabel: itemLabel,
                    annotations: annotations,
                    htmlMap: annotationHTMLMap,
                    restoringFormState: formState
                )
            },
            baseURL: URL(string: "galaxy://artifact-reader"),
            webView: $webViewRef,
            onAnnotationMessage: onAnnotationMessage,
            isInspectable: true
        )
    }
}

// MARK: - HTML Generation

private func buildMermaidHTML(
    content: String,
    isDark: Bool
) -> String {
    ReaderDocument.render(
        theme: .standard(isDark: isDark),
        title: "Galaxy Artifact Reader",
        css: """
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
        """,
        body: """
        <div class="mermaid-container">
        <pre class="mermaid">\(HTMLEscape.text(content))</pre>
        </div>
        """,
        // The diagram has to exist before the cards install, because a
        // whole-document anchor measures the rendered page.
        scriptsBeforeCards: """
        \(ReaderAssets.mermaidJS)
        if (typeof mermaid !== 'undefined') {
            mermaid.initialize({
                startOnLoad: false,
                theme: '\(isDark ? "dark" : "default")',
                securityLevel: 'loose',
            });
            mermaid.run();
        }
        """,
        cardScripts: .withoutAddNote
    )
}
