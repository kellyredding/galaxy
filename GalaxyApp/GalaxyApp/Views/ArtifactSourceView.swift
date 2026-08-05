import SwiftUI
import WebKit
import Galactic

/// Renders source code or plain text with line numbers and
/// syntax highlighting in a WKWebView. Uses the same vendored
/// highlight.js and theme CSS as MarkdownReaderView.
/// Supports line_range annotations via the shared
/// AnnotationManager JS.
struct ArtifactSourceView: View {
    let content: String
    let language: String?
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
                SourceRenderer.document(
                    content: content, language: language, isDark: isDark
                )
            },
            annotationInitJS: { formState in
                buildAnnotationInitJS(
                    anchoring: SourceRenderer.anchoring,
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
