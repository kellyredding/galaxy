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
    /// How many annotations a review would carry. Displayed by the send bar;
    /// the reader neither computes nor interprets it.
    let pendingReviewCount: Int
    let itemLabel: String
    /// Whether this reader is the surface in front of the user.
    /// Handed to `ReaderHostView`, which needs it to stop answering
    /// key equivalents from a tab the user has moved away from.
    let isVisibleSurface: Bool
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
                    restoringFormState: formState,
                    sendBarCount: pendingReviewCount
                )
            },
            baseURL: URL(string: "galaxy://artifact-reader"),
            webView: $webViewRef,
            isVisibleSurface: isVisibleSurface,
            onAnnotationMessage: onAnnotationMessage
        )
    }
}
