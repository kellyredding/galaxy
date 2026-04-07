import SwiftUI
import WebKit

/// Renders CSV content as a styled HTML table in a WKWebView.
/// Uses the same SilentFunctionKeyWebView and navigation
/// delegate pattern as ArtifactSourceView.
struct ArtifactTableView: NSViewRepresentable {
    let content: String
    let isDark: Bool
    @Binding var webViewRef: WKWebView?

    func makeNSView(
        context: Context
    ) -> SilentFunctionKeyWebView {
        let config = WKWebViewConfiguration()
        let webView = SilentFunctionKeyWebView(
            frame: .zero, configuration: config
        )
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate =
            context.coordinator

        webView.wantsLayer = true
        webView.layer?.backgroundColor =
            isDark
            ? NSColor.black.cgColor
            : NSColor.white.cgColor

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
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isDark: isDark)
    }

    class Coordinator: NSObject,
        WKNavigationDelegate
    {
        var lastIsDark: Bool

        init(isDark: Bool) {
            self.lastIsDark = isDark
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor nav: WKNavigationAction,
            decisionHandler: @escaping
                (WKNavigationActionPolicy) -> Void
        ) {
            if nav.navigationType == .linkActivated {
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
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

    var headerHTML = "<tr>"
    for cell in headerRow {
        let escaped = escapeHTML(cell)
        headerHTML += "<th>\(escaped)</th>"
    }
    headerHTML += "</tr>"

    var bodyHTML = ""
    for row in dataRows {
        bodyHTML += "<tr>"
        for cell in row {
            let escaped = escapeHTML(cell)
            bodyHTML += "<td>\(escaped)</td>"
        }
        bodyHTML += "</tr>"
    }

    return """
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8">
    <meta name="viewport"
          content="width=device-width, initial-scale=1">
    <title>Galaxy Artifact Reader</title>
    <style>
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
    </style>
    </head>
    <body>
    <div class="table-container">
    <table>
    <thead>\(headerHTML)</thead>
    <tbody>\(bodyHTML)</tbody>
    </table>
    </div>
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
