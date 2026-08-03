import SwiftUI
import WebKit
import Galactic

// AnnotationMessage enum is in AnnotationSupport.swift

// MARK: - MarkdownReaderView

/// Renders markdown content in a themed WKWebView with source-line
/// anchored blocks and inline annotation support.
///
/// The Coordinator acts as both WKScriptMessageHandler (receiving JS
/// messages) and WKNavigationDelegate (injecting annotations after
/// page load). The webViewRef binding exposes the WKWebView so the
/// parent view can call evaluateJavaScript for annotation actions.
struct MarkdownReaderView: View {
    let markdown: String
    let isDark: Bool
    let annotations: [any ReaderAnnotation]
    let annotationHTMLMap: [Int32: String]
    /// How many annotations a review would carry. Displayed by the send bar;
    /// the reader neither computes nor interprets it.
    let pendingReviewCount: Int
    @Binding var webViewRef: WKWebView?
    var onAnnotationMessage: ((AnnotationMessage) -> Void)?
    var annotationsEnabled: Bool = true
    /// Display label for annotation form headers
    /// (e.g. "Snapshot #3", "Artifact #19").
    let itemLabel: String
    /// Base URL name for internal routing
    /// (e.g. "snapshot-reader", "artifact-reader").
    var baseUrlName: String = "reader"
    // Absolute path of the file this artifact was created
    // from, when there was one. Used only to build a
    // copy-able reference; nothing about annotations
    // depends on it.
    var referencePath: String? = nil

    var body: some View {
        ReaderHostView(
            isDark: isDark,
            // Unlike the other readers this one's content can change under
            // it, so the source is part of what the page is built from. It
            // used to decide by rendering the document and comparing the
            // hash of the result — which meant building the page in full on
            // every pass in order to find out whether it needed building.
            reloadToken: [
                markdown.hashValue,
                isDark ? 1 : 0,
                annotationsEnabled ? 1 : 0,
            ],
            document: {
                MarkdownRenderer.document(markdown: markdown, isDark: isDark)
            },
            annotationInitJS: { formState in
                // A host can suppress the whole layer — a preview with
                // nothing to annotate against. Returning nothing installs
                // nothing, rather than installing a manager with no data.
                guard annotationsEnabled else { return "" }
                return buildAnnotationInitJS(
                    anchoring: MarkdownRenderer.anchoring,
                    itemLabel: itemLabel,
                    annotations: annotations,
                    htmlMap: annotationHTMLMap,
                    artifactContent: markdown,
                    referencePath: referencePath,
                    restoringFormState: formState,
                    sendBarCount: pendingReviewCount
                )
            },
            baseURL: URL(string: "galaxy://\(baseUrlName)"),
            webView: $webViewRef,
            onAnnotationMessage: onAnnotationMessage,
            isInspectable: true
        )
    }
}
