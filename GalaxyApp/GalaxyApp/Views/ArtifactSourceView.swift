import SwiftUI
import WebKit
import Galactic

/// How this reader anchors annotations into its markup.
let sourceAnchoring = ReaderAnchoring.lines(selector: ".code-line")

/// Renders source code or plain text with line numbers and
/// syntax highlighting in a WKWebView. Uses the same vendored
/// highlight.js and theme CSS as MarkdownReaderView.
/// Supports line_range annotations via the shared
/// AnnotationManager JS.
struct ArtifactSourceView: NSViewRepresentable {
    let content: String
    let language: String?
    let isDark: Bool
    let annotations: [any ReaderAnnotation]
    let annotationHTMLMap: [Int32: String]
    let itemLabel: String
    @Binding var webViewRef: WKWebView?
    var onAnnotationMessage:
        ((AnnotationMessage) -> Void)?
    // Absolute path of the file this artifact was created
    // from, when there was one. Used only to build a
    // copy-able reference; nothing about annotations
    // depends on it.
    var referencePath: String? = nil

    func makeNSView(
        context: Context
    ) -> ReaderWebView {
        let config = WKWebViewConfiguration()
        config.installGalaxyFindUserScript()
        config.userContentController.add(
            context.coordinator, name: "annotation"
        )
        let webView = ReaderWebView(
            frame: .zero, configuration: config
        )
        webView.setValue(
            false, forKey: "drawsBackground"
        )
        webView.navigationDelegate =
            context.coordinator

        webView.wantsLayer = true
        webView.layer?.backgroundColor =
            isDark
            ? NSColor.black.cgColor
            : NSColor.white.cgColor

        // Build init JS for after page load
        let initJS = buildAnnotationInitJS(
            anchoring: sourceAnchoring,
            itemLabel: itemLabel,
            annotations: annotations,
            htmlMap: annotationHTMLMap,
            artifactContent: content,
            referencePath: referencePath
        )
        context.coordinator.pendingInitJS = initJS
        context.coordinator.onAnnotationMessage =
            onAnnotationMessage

        let html = buildSourceHTML(
            content: content,
            language: language,
            isDark: isDark
        )
        webView.loadHTMLString(
            html,
            baseURL: URL(
                string: "galaxy://artifact-reader"
            )
        )

        DispatchQueue.main.async {
            webViewRef = webView
        }

        return webView
    }

    func updateNSView(
        _ webView: ReaderWebView,
        context: Context
    ) {
        if context.coordinator.lastIsDark != isDark {
            context.coordinator.lastIsDark = isDark

            webView.wantsLayer = true
            webView.layer?.backgroundColor =
                isDark
                ? NSColor.black.cgColor
                : NSColor.white.cgColor

            // Save form state before reload
            webView.evaluateJavaScript(
                "typeof AnnotationManager !== 'undefined'"
                + " ? JSON.stringify("
                + "AnnotationManager.getFormState())"
                + " : null"
            ) { result, _ in
                var initJS = buildAnnotationInitJS(
                    anchoring: sourceAnchoring,
                    itemLabel: itemLabel,
                    annotations: annotations,
                    htmlMap: annotationHTMLMap,
                    artifactContent: content,
                    referencePath: referencePath
                )
                if let stateJSON = result as? String {
                    initJS += "; AnnotationManager"
                        + ".restoreFormState("
                        + stateJSON + ")"
                }
                context.coordinator.pendingInitJS
                    = initJS

                let html = buildSourceHTML(
                    content: content,
                    language: language,
                    isDark: isDark
                )
                webView.loadHTMLString(
                    html,
                    baseURL: URL(
                        string:
                            "galaxy://artifact-reader"
                    )
                )
            }
        }
    }

    func makeCoordinator() -> AnnotationCoordinator {
        AnnotationCoordinator(isDark: isDark)
    }
}

// MARK: - HTML Generation

private func buildSourceHTML(
    content: String,
    language: String?,
    isDark: Bool
) -> String {
    let hjsContent = ReaderAssets.highlightJS
    let themeCSS = ReaderAssets.highlightThemeCSS(
        isDark: isDark
    )

    let theme = ReaderTheme.standard(isDark: isDark)

    // Build line-numbered code block
    let lines = content.components(separatedBy: "\n")
    var lineHTML = ""
    for (i, line) in lines.enumerated() {
        let lineNum = i + 1
        let escapedLine = HTMLEscape.text(line)
        lineHTML +=
            "<tr class=\"code-line\""
            + " data-line=\"\(lineNum)\">"
            + "<td class=\"line-num\">\(lineNum)</td>"
            + "<td class=\"line-content\">"
            + "\(escapedLine.isEmpty ? " " : escapedLine)"
            + "</td></tr>\n"
    }

    let langClass =
        language != nil
        ? "language-\(language!)"
        : "nohighlight"

    return ReaderDocument.render(
        theme: theme,
        title: "Galaxy Artifact Reader",
        fontFamily: ReaderFont.mono,
        css: """
        .source-container {
            width: 100%;
            overflow-x: auto;
        }
        table.source-table {
            border-collapse: collapse;
            width: max-content;
            min-width: 100%;
        }
        .code-line td {
            padding: 0 0;
            vertical-align: top;
            white-space: pre;
        }
        .line-num {
            width: 4em;
            min-width: 4em;
            max-width: 4em;
            text-align: right;
            padding-right: 12px !important;
            padding-left: 8px !important;
            color: \(theme.lineNumber);
            background: \(theme.gutter);
            user-select: none;
            -webkit-user-select: none;
            border-right: 1px solid
                \(isDark ? "#21262d" : "#d0d7de");
            position: sticky;
            left: 0;
            z-index: 1;
        }
        .line-content {
            padding-left: 12px !important;
            padding-right: 16px !important;
        }
        /* Override hljs background — we handle it */
        .hljs { background: transparent !important; }
        /* Annotation highlight adaption for table rows */
        .code-line.annotation-highlight td {
            background-color: rgba(88, 166, 255, 0.12);
        }
        .code-line.annotation-highlight .line-num {
            border-left: 3px solid
                rgba(88, 166, 255, 0.6);
            padding-left: 5px !important;
        }
        .code-line.annotation-expanded-highlight td {
            background-color:
                var(--annotation-active-block-bg);
        }
        .code-line.annotation-expanded-highlight .line-num {
            border-left: 3px solid
                var(--annotation-active-block-border);
            padding-left: 5px !important;
        }
        \(themeCSS)
        """,
        body: """
        <div class="source-container">
        <table class="source-table">
        <tbody class="\(langClass)">
        \(lineHTML)
        </tbody>
        </table>
        </div>
        """,
        // Highlight before the cards install: the manager measures the
        // rows it anchors to, and highlighting rewrites their contents.
        scriptsBeforeCards: """
        \(hjsContent)
        if (typeof hljs !== 'undefined') {
            document.querySelectorAll('.line-content')
                .forEach(function(el) {
                    hljs.highlightElement(el);
                });
        }
        """
    )
}
