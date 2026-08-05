import SwiftUI
import WebKit
import Galactic

/// Renders CSV content as a styled HTML table in a WKWebView.
/// Supports row_range annotations via the shared
/// AnnotationManager JS.
struct ArtifactTableView: View {
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
    // Absolute path of the file this artifact was created from, when there
    // was one. Used only to build a copy-able reference; nothing about
    // annotations depends on it.
    var referencePath: String? = nil

    var body: some View {
        ReaderHostView(
            isDark: isDark,
            reloadToken: isDark,
            document: {
                TableRenderer.document(content: content, isDark: isDark)
            },
            annotationInitJS: { formState in
                buildAnnotationInitJS(
                    anchoring: TableRenderer.anchoring,
                    itemLabel: itemLabel,
                    annotations: annotations,
                    htmlMap: annotationHTMLMap,
                    artifactContent: content,
                    referencePath: referencePath,
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
