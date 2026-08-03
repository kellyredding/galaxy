import SwiftUI
import WebKit
import Galactic

/// Renders image artifacts (PNG, JPG, GIF, SVG, WebP) in
/// a WKWebView for consistent zoom support via
/// ReaderWebView and annotation via the
/// generalized AnnotationManager JS.
struct ArtifactImageView: View {
    let filePath: String
    let isDark: Bool
    let annotations: [any ReaderAnnotation]
    let annotationHTMLMap: [Int32: String]
    /// How many annotations a review would carry. Displayed by the send bar;
    /// the reader neither computes nor interprets it.
    let pendingReviewCount: Int
    let itemLabel: String
    var onAnnotationMessage: ((AnnotationMessage) -> Void)?
    @Binding var webViewRef: WKWebView?

    var body: some View {
        ReaderHostView(
            isDark: isDark,
            reloadToken: isDark,
            document: {
                ImageRenderer.document(filePath: filePath, isDark: isDark)
            },
            annotationInitJS: { formState in
                buildAnnotationInitJS(
                    anchoring: ImageRenderer.anchoring,
                    itemLabel: itemLabel,
                    annotations: annotations,
                    htmlMap: annotationHTMLMap,
                    restoringFormState: formState,
                    sendBarCount: pendingReviewCount
                )
            },
            baseURL: URL(
                fileURLWithPath: (filePath as NSString)
                    .deletingLastPathComponent
            ),
            webView: $webViewRef,
            onAnnotationMessage: onAnnotationMessage,
            isInspectable: true
        )
    }
}
