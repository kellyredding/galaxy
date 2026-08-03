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
    let itemLabel: String
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
                    restoringFormState: formState
                )
            },
            baseURL: URL(string: "galaxy://artifact-reader"),
            webView: $webViewRef,
            onAnnotationMessage: onAnnotationMessage
        )
    }
}
