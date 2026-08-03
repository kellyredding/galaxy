import SwiftUI
import WebKit
import Galactic

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
                MermaidRenderer.document(content: content, isDark: isDark)
            },
            annotationInitJS: { formState in
                buildAnnotationInitJS(
                    anchoring: MermaidRenderer.anchoring,
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
