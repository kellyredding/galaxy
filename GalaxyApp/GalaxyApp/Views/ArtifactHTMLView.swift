import SwiftUI
import WebKit
import Galactic

/// Renders HTML artifacts in a sandboxed WKWebView.
/// External links open in the default browser.
/// Supports block_range annotations via the shared
/// AnnotationManager JS with a DOM-walk block-index
/// pass after page load.
struct ArtifactHTMLView: View {
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
                HTMLRenderer.document(content: content, isDark: isDark)
            },
            annotationInitJS: { formState in
                buildAnnotationInitJS(
                    anchoring: HTMLRenderer.anchoring,
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
