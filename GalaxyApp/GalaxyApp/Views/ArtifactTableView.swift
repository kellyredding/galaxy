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
    let itemLabel: String
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
                    restoringFormState: formState
                )
            },
            baseURL: URL(string: "galaxy://artifact-reader"),
            webView: $webViewRef,
            onAnnotationMessage: onAnnotationMessage
        )
    }
}
