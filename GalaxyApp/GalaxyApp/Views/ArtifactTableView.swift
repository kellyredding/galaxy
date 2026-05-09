import SwiftUI
import WebKit

/// Renders CSV content as a styled HTML table in a WKWebView.
/// Supports row_range annotations via the shared
/// AnnotationManager JS.
struct ArtifactTableView: NSViewRepresentable {
    let content: String
    let isDark: Bool
    let annotations: [ArtifactAnnotation]
    let annotationHTMLMap: [Int32: String]
    let itemLabel: String
    @Binding var webViewRef: WKWebView?
    var onAnnotationMessage:
        ((AnnotationMessage) -> Void)?

    func makeNSView(
        context: Context
    ) -> SilentFunctionKeyWebView {
        let config = WKWebViewConfiguration()
        config.installGalaxyFindUserScript()
        config.userContentController.add(
            context.coordinator, name: "annotation"
        )
        let webView = SilentFunctionKeyWebView(
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

        let activeAnns = annotations.filter {
            !$0.stale
                && $0.anchorData.type == .rowRange
        }
        let initJS = buildAnnotationInitJS(
            anchorType: "row_range",
            blockSelector: "tr[data-row]",
            lineAttr: "data-row",
            refPrefix: "Row",
            itemLabel: itemLabel,
            annotations: activeAnns,
            htmlMap: annotationHTMLMap,
            artifactContent: content
        )
        context.coordinator.pendingInitJS = initJS
        context.coordinator.onAnnotationMessage =
            onAnnotationMessage

        let html = buildTableHTML(
            content: content,
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
        _ webView: SilentFunctionKeyWebView,
        context: Context
    ) {
        if context.coordinator.lastIsDark != isDark {
            context.coordinator.lastIsDark = isDark

            webView.wantsLayer = true
            webView.layer?.backgroundColor =
                isDark
                ? NSColor.black.cgColor
                : NSColor.white.cgColor

            webView.evaluateJavaScript(
                "typeof AnnotationManager !== 'undefined'"
                + " ? JSON.stringify("
                + "AnnotationManager.getFormState())"
                + " : null"
            ) { result, _ in
                let activeAnns = annotations.filter {
                    !$0.stale
                        && $0.anchorData.type
                            == .rowRange
                }
                var initJS = buildAnnotationInitJS(
                    anchorType: "row_range",
                    blockSelector: "tr[data-row]",
                    lineAttr: "data-row",
                    refPrefix: "Row",
                    itemLabel: itemLabel,
                    annotations: activeAnns,
                    htmlMap: annotationHTMLMap,
                    artifactContent: content
                )
                if let stateJSON = result as? String {
                    initJS += "; AnnotationManager"
                        + ".restoreFormState("
                        + stateJSON + ")"
                }
                context.coordinator.pendingInitJS
                    = initJS

                let html = buildTableHTML(
                    content: content,
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

private func buildTableHTML(
    content: String,
    isDark: Bool
) -> String {
    let bgColor = isDark ? "#0d1117" : "#ffffff"
    let textColor = isDark ? "#e6edf3" : "#1f2328"
    let headerBg = isDark ? "#161b22" : "#f6f8fa"
    let borderColor = isDark ? "#30363d" : "#d0d7de"
    let stripeBg = isDark ? "#0d1117" : "#ffffff"
    let stripeAltBg = isDark ? "#161b22" : "#f6f8fa"

    let rows = parseCSV(content)
    guard !rows.isEmpty else {
        return "<html><body>No data</body></html>"
    }

    let headerRow = rows[0]
    let dataRows = Array(rows.dropFirst())

    var headerHTML = "<tr data-row=\"0\">"
    for cell in headerRow {
        let escaped = escapeHTML(cell)
        headerHTML += "<th>\(escaped)</th>"
    }
    headerHTML += "</tr>"

    var bodyHTML = ""
    for (i, row) in dataRows.enumerated() {
        let rowNum = i + 1
        bodyHTML += "<tr data-row=\"\(rowNum)\">"
        for cell in row {
            let escaped = escapeHTML(cell)
            bodyHTML += "<td>\(escaped)</td>"
        }
        bodyHTML += "</tr>"
    }

    let cssVars = annotationCSSVars(isDark: isDark)

    return """
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8">
    <meta name="viewport"
          content="width=device-width, initial-scale=1">
    <title>Galaxy Artifact Reader</title>
    <style>
    :root {
        \(cssVars)
    }
    * { margin: 0; padding: 0; box-sizing: border-box; }
    html, body {
        background: \(bgColor);
        color: \(textColor);
        font-family: -apple-system, BlinkMacSystemFont,
            'SF Pro Text', 'Helvetica Neue', sans-serif;
        font-size: 13px;
        line-height: 1.45;
        -webkit-font-smoothing: antialiased;
    }
    .table-container {
        padding: 16px;
        overflow: auto;
    }
    table {
        border-collapse: collapse;
        width: 100%;
        border: 1px solid \(borderColor);
    }
    th {
        background: \(headerBg);
        font-weight: 600;
        text-align: left;
        padding: 8px 12px;
        border: 1px solid \(borderColor);
        white-space: nowrap;
    }
    td {
        padding: 6px 12px;
        border: 1px solid \(borderColor);
        white-space: nowrap;
    }
    tr:nth-child(even) {
        background: \(stripeAltBg);
    }
    tr:nth-child(odd) {
        background: \(stripeBg);
    }
    /* Annotation highlight for table rows */
    tr.annotation-highlight td {
        background-color: rgba(88, 166, 255, 0.12);
        border-left-color: rgba(88, 166, 255, 0.6);
    }
    tr.annotation-expanded-highlight td {
        background-color:
            var(--annotation-active-block-bg);
        border-left-color:
            var(--annotation-active-block-border);
    }
    \(annotationCSS)
    </style>
    </head>
    <body>
    <div class="table-container">
    <table>
    <thead>\(headerHTML)</thead>
    <tbody>\(bodyHTML)</tbody>
    </table>
    </div>
    <script>\(clipboardCopyJS)</script>
    <script>\(suggestionInsertJS)</script>
    <script>
    \(annotationManagerJS)
    </script>
    <script>\(emojiDataJS)</script>
    <script>\(emojiAutocompleteJS)</script>
    </body>
    </html>
    """
}

/// Simple CSV parser that handles quoted fields.
private func parseCSV(_ content: String) -> [[String]] {
    var rows: [[String]] = []
    var currentRow: [String] = []
    var currentField = ""
    var inQuotes = false
    let chars = Array(content)
    var i = 0

    while i < chars.count {
        let ch = chars[i]

        if inQuotes {
            if ch == "\"" {
                // Check for escaped quote
                if i + 1 < chars.count
                    && chars[i + 1] == "\""
                {
                    currentField.append("\"")
                    i += 2
                    continue
                }
                inQuotes = false
            } else {
                currentField.append(ch)
            }
        } else {
            if ch == "\"" {
                inQuotes = true
            } else if ch == "," {
                currentRow.append(currentField)
                currentField = ""
            } else if ch == "\n" || ch == "\r" {
                // Handle \r\n
                if ch == "\r" && i + 1 < chars.count
                    && chars[i + 1] == "\n"
                {
                    i += 1
                }
                currentRow.append(currentField)
                currentField = ""
                if !currentRow.isEmpty {
                    rows.append(currentRow)
                }
                currentRow = []
            } else {
                currentField.append(ch)
            }
        }
        i += 1
    }

    // Last field/row
    if !currentField.isEmpty
        || !currentRow.isEmpty
    {
        currentRow.append(currentField)
        rows.append(currentRow)
    }

    return rows
}

private func escapeHTML(_ text: String) -> String {
    text
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}
