import Foundation
import SwiftTerm

/// Converts a frozen SwiftTerm `Buffer` snapshot into a complete HTML document
/// that visually matches the live terminal rendering. Each `BufferLine` becomes
/// a `<div class="tl">` with styled `<span>` runs for each attribute group.
///
/// The HTML includes embedded CSS (font, colors, line-height matching the
/// terminal) and a JavaScript `ScrollbackManager` that handles keyboard
/// navigation, scroll position, and Swift ↔ WKWebView communication.
enum ScrollbackBufferRenderer {

    // MARK: - Public API

    /// Render a frozen buffer snapshot to a complete HTML document string.
    ///
    /// - Parameters:
    ///   - buffer: Deep-copy buffer from `terminal.snapshotBuffer()`
    ///   - terminal: The terminal instance (needed for extended grapheme lookup)
    ///   - theme: Current color theme for default/ANSI colors
    ///   - fontFamily: CSS font-family value (e.g. "SF Mono", "Menlo")
    ///   - fontSize: Font size in points
    ///   - cellHeight: Pixel height of one terminal line (from cellDimension.height)
    ///   - cols: Column count of the buffer
    static func render(
        buffer: Buffer,
        terminal: Terminal,
        theme: TerminalColorTheme,
        fontFamily: String,
        fontSize: CGFloat,
        cellHeight: CGFloat,
        cols: Int
    ) -> String {
        let resolver = ColorResolver(theme: theme)
        var html = ""
        html.reserveCapacity(buffer.lines.count * cols * 4)  // rough estimate

        let lineCount = buffer.lines.count
        for lineIdx in 0..<lineCount {
            let line = buffer.lines[lineIdx]
            html.append(renderLine(line, lineIndex: lineIdx, cols: cols,
                                   terminal: terminal, resolver: resolver))
        }

        return wrapDocument(
            body: html,
            theme: theme,
            fontFamily: fontFamily,
            fontSize: fontSize,
            cellHeight: cellHeight
        )
    }

    // MARK: - Line Rendering

    private static func renderLine(
        _ line: BufferLine,
        lineIndex: Int,
        cols: Int,
        terminal: Terminal,
        resolver: ColorResolver
    ) -> String {
        var spans = ""
        var currentAttr: Attribute? = nil
        var currentText = ""
        var currentStartCol = 0  // column where current span starts
        var currentCol = 0       // current column position
        let cellCount = min(cols, line.count)

        for col in 0..<cellCount {
            let cell = line[col]

            // Skip continuation cells (wide character second column)
            if cell.width == 0 { continue }

            let char: String
            if cell.code == 0 && cell.width == 1 {
                // Null cell — emit space
                char = " "
            } else if cell.code < Int32(CharData.maxRune) {
                if let scalar = Unicode.Scalar(UInt32(cell.code)) {
                    char = htmlEscape(String(Character(scalar)))
                } else {
                    char = " "
                }
            } else {
                // Extended grapheme cluster
                let character = terminal.getCharacter(for: cell)
                char = htmlEscape(String(character))
            }

            // cell.width is the column span (1 for normal, 2 for wide chars)
            let colSpan = Int(cell.width)

            if cell.attribute == currentAttr {
                currentText.append(char)
                currentCol += colSpan
            } else {
                // Flush previous run with absolute position
                if let attr = currentAttr, !currentText.isEmpty {
                    let colCount = currentCol - currentStartCol
                    spans.append(spanTag(for: attr, text: currentText,
                                         startCol: currentStartCol,
                                         colCount: colCount,
                                         resolver: resolver))
                }
                currentAttr = cell.attribute
                currentText = char
                currentStartCol = currentCol
                currentCol += colSpan
            }
        }

        // Flush final run
        if let attr = currentAttr, !currentText.isEmpty {
            let colCount = currentCol - currentStartCol
            spans.append(spanTag(for: attr, text: currentText,
                                 startCol: currentStartCol,
                                 colCount: colCount,
                                 resolver: resolver))
        }

        if spans.isEmpty {
            return "<div class=\"tl\" data-line=\"\(lineIndex)\">&nbsp;</div>"
        }
        return "<div class=\"tl\" data-line=\"\(lineIndex)\">\(spans)</div>"
    }

    // MARK: - Span Generation

    private static func spanTag(
        for attr: Attribute,
        text: String,
        startCol: Int,
        colCount: Int,
        resolver: ColorResolver
    ) -> String {
        let style = attr.style
        let isBold = style.contains(.bold)
        let isInverse = style.contains(.inverse)

        // Resolve colors (handle inverse swap)
        var fgHex = resolver.fgColor(attr.fg, isBold: isBold)
        var bgHex = resolver.bgColor(attr.bg)

        if isInverse {
            let tmpFg = fgHex ?? resolver.theme.foreground
            let tmpBg = bgHex  // nil means transparent (theme background)
            fgHex = tmpBg ?? resolver.theme.background
            bgHex = tmpFg
        }

        // Use CSS `ch` units for positioning — `ch` is the browser's own
        // measurement of one character advance width in the current font.
        // This eliminates the mismatch between Swift's CTFont cellWidth
        // and WebKit's font metrics that caused span boundary artifacts.
        var css = "position:absolute;left:\(startCol)ch;width:\(colCount)ch;overflow:hidden;"
        if let fg = fgHex { css.append("color:\(fg);") }
        if let bg = bgHex { css.append("background-color:\(bg);") }
        // Use -webkit-text-stroke instead of font-weight:bold. CSS bold
        // synthesis widens glyphs, breaking the monospace cell grid. Core
        // Text (used by SwiftTerm) renders bold by thickening strokes at
        // fixed glyph positions — text-stroke replicates that behavior.
        if isBold { css.append("-webkit-text-stroke:0.5px currentColor;") }
        if style.contains(.italic) { css.append("font-style:italic;") }
        if style.contains(.dim) { css.append("opacity:0.5;") }
        if style.contains(.invisible) { css.append("visibility:hidden;") }

        // Text decoration (combine underline + strikethrough)
        var decorations: [String] = []
        if style.contains(.underline) { decorations.append("underline") }
        if style.contains(.crossedOut) { decorations.append("line-through") }
        if !decorations.isEmpty {
            css.append("text-decoration:\(decorations.joined(separator: " "));")
        }

        return "<span style=\"\(css)\">\(text)</span>"
    }

    // MARK: - HTML Document Wrapper

    private static func wrapDocument(
        body: String,
        theme: TerminalColorTheme,
        fontFamily: String,
        fontSize: CGFloat,
        cellHeight: CGFloat
    ) -> String {
        // Map font family for CSS — system monospace needs special handling
        let cssFontFamily: String
        if fontFamily.contains("SFMono") || fontFamily == "SF Mono" ||
            fontFamily.hasPrefix(".SFNSMono") || fontFamily.hasPrefix(".AppleSystemUIFontMonospaced") {
            cssFontFamily = "ui-monospace, \"SF Mono\", monospace"
        } else {
            cssFontFamily = "\"\(fontFamily)\", ui-monospace, monospace"
        }

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style id="base-theme">
        :root {
            --fg: \(theme.foreground);
            --bg: \(theme.background);
            --font-family: \(cssFontFamily);
            --font-size: \(fontSize)px;
            --line-height: \(cellHeight)px;
        }
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            background: var(--bg);
            color: var(--fg);
            font-family: var(--font-family);
            font-size: var(--font-size);
            line-height: var(--line-height);
            overflow-x: hidden;
            overscroll-behavior: none;
            -webkit-font-smoothing: antialiased;
            -webkit-user-select: text;
            cursor: text;
        }
        pre {
            margin: 0;
            font-family: inherit;
            font-size: inherit;
            line-height: inherit;
        }
        .tl {
            position: relative;
            height: var(--line-height);
            white-space: pre;
            overflow: hidden;
        }
        ::selection {
            background-color: rgba(88, 166, 255, 0.3);
        }
        </style>
        </head>
        <body>
        <pre id="terminal-content">\(body)</pre>
        <script>
        \(scrollbackManagerJS)
        </script>
        </body>
        </html>
        """
    }

    // MARK: - JavaScript

    private static let scrollbackManagerJS = """
    const ScrollbackManager = {
        lineHeight: 0,
        totalLines: 0,
        container: null,

        initialize() {
            // Use the document scrolling element (document-level scroll)
            // so WKWebView's native scroll indicator is visible.
            this.container = document.scrollingElement || document.documentElement;
            const firstLine = document.querySelector('.tl');
            if (firstLine) {
                this.lineHeight = firstLine.getBoundingClientRect().height;
            }
            this.totalLines = document.querySelectorAll('.tl').length;

            // Add bottom padding to compensate for the fractional row gap.
            // The viewport height rarely divides evenly by cellHeight,
            // leaving a gap of (viewportHeight % cellHeight) pixels at the
            // bottom. Without this padding, scrollTop is clamped short of the
            // target when scrolling to the last screenful, shifting content
            // down by the gap amount.
            const gap = window.innerHeight % this.lineHeight;
            if (gap > 0) {
                document.getElementById('terminal-content').style.paddingBottom = gap + 'px';
            }

            document.addEventListener('keydown', (e) => this.handleKey(e));

            window.webkit.messageHandlers.scrollback.postMessage({
                action: 'ready'
            });
        },

        handleKey(e) {
            const c = this.container;
            switch (e.key) {
            case 'Escape':
                e.preventDefault();
                window.webkit.messageHandlers.scrollback.postMessage({
                    action: 'dismiss'
                });
                break;
            case 'ArrowUp':
                if (!e.metaKey && !e.shiftKey) {
                    e.preventDefault();
                    c.scrollTop -= this.lineHeight;
                }
                break;
            case 'ArrowDown':
                if (!e.metaKey && !e.shiftKey) {
                    e.preventDefault();
                    c.scrollTop += this.lineHeight;
                }
                break;
            case 'PageUp':
                e.preventDefault();
                c.scrollTop -= c.clientHeight;
                break;
            case 'PageDown':
                e.preventDefault();
                c.scrollTop += c.clientHeight;
                break;
            case 'Home':
                e.preventDefault();
                c.scrollTop = 0;
                break;
            case 'End':
                e.preventDefault();
                c.scrollTop = c.scrollHeight;
                break;
            }
        },

        scrollToLine(lineIndex) {
            const line = document.querySelector(`[data-line="${lineIndex}"]`);
            if (line) {
                this.container.scrollTop = line.offsetTop;
            }
        },

        updateTheme(css) {
            let el = document.getElementById('dynamic-theme');
            if (!el) {
                el = document.createElement('style');
                el.id = 'dynamic-theme';
                document.head.appendChild(el);
            }
            el.textContent = css;
        },

        getVisibleLine() {
            const c = this.container;
            const scrollTop = c.scrollTop;
            const lines = document.querySelectorAll('.tl');
            for (const line of lines) {
                if (line.offsetTop >= scrollTop) {
                    return parseInt(line.dataset.line);
                }
            }
            return 0;
        }
    };

    document.addEventListener('DOMContentLoaded', () => {
        ScrollbackManager.initialize();
    });
    """

    // MARK: - HTML Escaping

    private static func htmlEscape(_ str: String) -> String {
        var result = str
        result = result.replacingOccurrences(of: "&", with: "&amp;")
        result = result.replacingOccurrences(of: "<", with: "&lt;")
        result = result.replacingOccurrences(of: ">", with: "&gt;")
        result = result.replacingOccurrences(of: "\"", with: "&quot;")
        return result
    }
}

// MARK: - Color Resolver

extension ScrollbackBufferRenderer {

    /// Resolves `Attribute.Color` values to CSS hex strings using the same
    /// logic as SwiftTerm's `mapColor()` in AppleTerminalView. The first 16
    /// palette entries come from the theme's `ansiColors`; 16-231 are the
    /// 6×6×6 RGB cube; 232-255 are the grayscale ramp.
    struct ColorResolver {
        let theme: TerminalColorTheme
        private let palette: [String]  // 256 hex colors

        init(theme: TerminalColorTheme) {
            self.theme = theme
            var p = [String]()
            p.reserveCapacity(256)

            // First 16 from theme
            for hex in theme.ansiColors {
                p.append(hex)
            }

            // 216 color cube (indices 16-231)
            for r in 0..<6 {
                for g in 0..<6 {
                    for b in 0..<6 {
                        let rv = r > 0 ? r * 40 + 55 : 0
                        let gv = g > 0 ? g * 40 + 55 : 0
                        let bv = b > 0 ? b * 40 + 55 : 0
                        p.append(String(format: "#%02X%02X%02X", rv, gv, bv))
                    }
                }
            }

            // 24 grayscale (indices 232-255)
            for i in 0..<24 {
                let v = i * 10 + 8
                p.append(String(format: "#%02X%02X%02X", v, v, v))
            }

            self.palette = p
        }

        /// Resolve foreground color. Returns nil to use the CSS default (--fg).
        func fgColor(_ color: Attribute.Color, isBold: Bool) -> String? {
            switch color {
            case .defaultColor:
                // Bold + default fg → use bold foreground color from theme
                if isBold {
                    return theme.boldForeground ?? theme.ansiColors[15]
                }
                return nil  // Use CSS var(--fg)

            case .defaultInvertedColor:
                // Inverted default — return background color as foreground
                return theme.background

            case .ansi256(let code):
                let idx: Int
                // Bright promotion: bold + normal color (0-7) → bright (8-15)
                if isBold && code < 8 {
                    idx = Int(code) + 8
                } else {
                    idx = Int(code)
                }
                guard idx < palette.count else { return nil }
                return palette[idx]

            case .trueColor(let r, let g, let b):
                return String(format: "#%02X%02X%02X", r, g, b)
            }
        }

        /// Resolve background color. Returns nil for transparent (theme default bg).
        func bgColor(_ color: Attribute.Color) -> String? {
            switch color {
            case .defaultColor, .defaultInvertedColor:
                return nil  // Transparent — inherits body background

            case .ansi256(let code):
                let idx = Int(code)
                guard idx < palette.count else { return nil }
                return palette[idx]

            case .trueColor(let r, let g, let b):
                return String(format: "#%02X%02X%02X", r, g, b)
            }
        }
    }
}
