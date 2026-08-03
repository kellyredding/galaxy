import SwiftUI
import WebKit
import Galactic

/// Renders JSONL agent transcript artifacts as a
/// structured HTML conversation document.
/// Each logical step (thinking, tool call, summary)
/// is an annotatable block. Tool call details are
/// collapsible via <details> elements.
struct ArtifactTranscriptView: View {
    let content: String
    let isDark: Bool
    let annotations: [any ReaderAnnotation]
    let annotationHTMLMap: [Int32: String]
    let itemLabel: String
    @Binding var webViewRef: WKWebView?
    var onAnnotationMessage: ((AnnotationMessage) -> Void)?

    var body: some View {
        ReaderHostView(
            isDark: isDark,
            reloadToken: isDark,
            document: {
                TranscriptRenderer.document(content: content, isDark: isDark)
            },
            annotationInitJS: { formState in
                buildAnnotationInitJS(
                    anchoring: TranscriptRenderer.anchoring,
                    itemLabel: itemLabel,
                    annotations: annotations,
                    htmlMap: annotationHTMLMap,
                    restoringFormState: formState
                )
            },
            baseURL: URL(string: "galaxy://artifact-reader"),
            webView: $webViewRef,
            onAnnotationMessage: onAnnotationMessage
        )
    }
}
