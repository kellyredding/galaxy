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

        // Detect light vs dark theme for note styling CSS class
        let isLight = theme.backgroundLuminance > 0.5

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
            --delete-color: #d63031;
            --annotation-active-border: rgba(255, 220, 50, 0.5);
            --annotation-active-bg: rgba(255, 255, 120, 0.12);
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
            padding-bottom: 48px;
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
        \(noteCSS(isLight: isLight))
        </style>
        </head>
        <body\(isLight ? " class=\"light\"" : "")>
        <pre id="terminal-content">\(body)</pre>
        <div class="send-bar" id="send-bar" style="display:none;">
            <span class="send-bar-count" id="send-bar-count">0 notes</span>
            <button class="send-bar-button" id="send-bar-button">Send to Claude ⌘⇧↩</button>
        </div>
        <script>\(emojiDataJS)</script>
        <script>\(emojiAutocompleteJS)</script>
        <script>
        \(scrollbackManagerJS)
        \(noteManagerJS)
        </script>
        </body>
        </html>
        """
    }

    // MARK: - Emoji JS (inlined from bundle resources)

    private static let emojiDataJS: String = {
        guard let url = Bundle.main.url(forResource: "emoji-data", withExtension: "js"),
              let content = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return content
    }()

    private static let emojiAutocompleteJS: String = {
        guard let url = Bundle.main.url(forResource: "emoji-autocomplete", withExtension: "js"),
              let content = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return content
    }()

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

            // Initialize note manager
            this.notes.initialize();

            window.webkit.messageHandlers.scrollback.postMessage({
                action: 'ready'
            });
        },

        handleKey(e) {
            // Let textareas handle their own arrow/cursor keys
            if (e.target.tagName === 'TEXTAREA') return;

            const c = this.container;
            switch (e.key) {
            case 'Escape':
                e.preventDefault();
                this.handleEscape();
                break;
            case 'Enter':
                // Cmd+Shift+Enter — send notes to Claude
                if (e.metaKey && e.shiftKey && this.notes.items.length > 0) {
                    e.preventDefault();
                    this.notes.sendToClaude();
                }
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

        handleEscape() {
            const n = this.notes;

            // 1. Editing a note — cancel edit
            if (n.editingId) {
                const note = n.items.find(x => x.id === n.editingId);
                if (note) n.cancelEdit(n.editingId, note.content);
                return;
            }

            // 2. Note expanded — collapse
            if (n.expandedId) {
                n.toggleExpand(n.expandedId);
                return;
            }

            // 3. Form has text — clear it
            if (n.formElement && n.formElement.style.display !== 'none') {
                const ta = n.formElement.querySelector('textarea');
                if (ta && ta.value.length > 0) {
                    ta.value = '';
                    ta.style.height = 'auto';
                    return;
                }
                // 4. Form visible but empty — hide
                n.hideForm();
                n.clearHighlights();
                return;
            }

            // 5. Has notes — confirm dismiss
            if (n.items.length > 0) {
                window.webkit.messageHandlers.scrollback.postMessage({
                    action: 'confirmDismiss'
                });
                return;
            }

            // 6. No notes — dismiss scrollback
            window.webkit.messageHandlers.scrollback.postMessage({
                action: 'dismiss'
            });
        },

        scrollToLine(lineIndex) {
            const line = document.querySelector('[data-line=\"' + lineIndex + '\"]');
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

    // MARK: - Note CSS

    private static func noteCSS(isLight: Bool) -> String {
        let formBg = isLight
            ? "rgba(255, 255, 255, 0.95)"
            : "rgba(30, 30, 30, 0.95)"
        let formBorder = isLight
            ? "rgba(88, 166, 255, 0.5)"
            : "rgba(88, 166, 255, 0.4)"
        let cardBg = isLight
            ? "rgba(255, 255, 255, 0.92)"
            : "rgba(30, 30, 30, 0.9)"
        let textColor = isLight
            ? "rgba(0, 0, 0, 0.5)"
            : "rgba(255, 255, 255, 0.5)"
        let textColorFaint = isLight
            ? "rgba(0, 0, 0, 0.3)"
            : "rgba(255, 255, 255, 0.3)"
        let textColorHover = isLight
            ? "rgba(0, 0, 0, 0.8)"
            : "rgba(255, 255, 255, 0.8)"
        let inputBg = isLight
            ? "rgba(0, 0, 0, 0.04)"
            : "rgba(255, 255, 255, 0.05)"
        let inputBorder = isLight
            ? "rgba(0, 0, 0, 0.12)"
            : "rgba(255, 255, 255, 0.1)"
        let cardBorder = isLight
            ? "rgba(0, 0, 0, 0.1)"
            : "rgba(255, 255, 255, 0.1)"
        let cardBorderHover = isLight
            ? "rgba(0, 0, 0, 0.2)"
            : "rgba(255, 255, 255, 0.2)"
        let highlightBg = isLight
            ? "rgba(88, 166, 255, 0.15)"
            : "rgba(88, 166, 255, 0.25)"
        let highlightBorder = isLight
            ? "rgba(88, 166, 255, 0.7)"
            : "rgba(88, 166, 255, 0.8)"
        let expandHighlightBg = isLight
            ? "rgba(255, 220, 50, 0.10)"
            : "rgba(255, 255, 120, 0.12)"
        let expandHighlightBorder = isLight
            ? "rgba(255, 200, 30, 0.6)"
            : "rgba(255, 220, 50, 0.7)"
        let sendBarBg = isLight
            ? "rgba(34, 139, 34, 0.92)"
            : "rgba(40, 170, 80, 0.95)"
        let sendBarBorderTop = isLight
            ? "rgba(0, 0, 0, 0.1)"
            : "rgba(255, 255, 255, 0.15)"
        let sendBtnBg = isLight
            ? "rgba(255, 255, 255, 0.25)"
            : "rgba(255, 255, 255, 0.2)"
        let sendBtnBorder = isLight
            ? "rgba(255, 255, 255, 0.35)"
            : "rgba(255, 255, 255, 0.3)"

        return """
        /* Note line highlights — use box-shadow for left border so
           padding/margin don't shift the absolutely-positioned spans
           inside .tl divs. The .tl overflow:hidden clips painting,
           so we temporarily override it on highlighted lines. */
        .note-highlight {
            background-color: \(highlightBg) !important;
        }
        .note-highlight::before {
            content: '';
            position: absolute;
            left: 6px;
            top: 0;
            bottom: 0;
            width: 4px;
            background: \(highlightBorder);
            z-index: 10;
            border-radius: 1px;
        }
        .note-expanded-highlight {
            background-color: \(expandHighlightBg) !important;
        }
        .note-expanded-highlight::before {
            content: '';
            position: absolute;
            left: 6px;
            top: 0;
            bottom: 0;
            width: 4px;
            background: \(expandHighlightBorder);
            z-index: 10;
            border-radius: 1px;
        }

        /* Note form — in flow, matches snapshot annotation form styling */
        .note-form {
            position: relative;
            margin: 4px 24px;
            z-index: 100;
            padding: 8px 12px;
            border: 1px solid \(formBorder);
            border-radius: 6px;
            background: \(formBg);
            box-sizing: border-box;
            display: none;
            white-space: normal;
        }
        .note-form-header {
            font-size: 11px;
            color: \(textColor);
            margin-bottom: 4px;
            font-family: var(--font-family);
        }
        .note-textarea {
            width: 100%;
            min-height: 1.6em;
            padding: 6px 8px;
            border: 1px solid \(inputBorder);
            border-radius: 4px;
            background: var(--bg);
            color: var(--fg);
            font-family: -apple-system, system-ui, sans-serif;
            font-size: 13px;
            line-height: 1.5;
            resize: none;
            overflow: hidden;
            box-sizing: border-box;
        }
        .note-textarea:focus {
            outline: none;
            border-color: rgba(88, 166, 255, 0.6);
        }
        .note-textarea::placeholder {
            color: \(textColor);
            opacity: 1;
        }

        /* Note cards — positioned in flow after their target line */
        .note-card {
            position: relative;
            margin: 4px 24px;
            z-index: 90;
            background: \(cardBg);
            border: 1px solid \(cardBorder);
            border-radius: 6px;
            padding: 6px 10px;
            font-family: -apple-system, system-ui, sans-serif;
            cursor: pointer;
            box-sizing: border-box;
            white-space: normal;
        }
        .note-card:hover {
            border-color: \(cardBorderHover);
        }
        .note-card.expanded {
            border-color: var(--annotation-active-border);
            background: var(--annotation-active-bg);
        }
        .note-card-header {
            display: flex;
            align-items: center;
            gap: 8px;
            font-size: 11px;
            color: \(textColor);
        }
        .note-card-ref { font-weight: 500; }
        .note-card-meta { color: \(textColorFaint); }
        .note-card-actions {
            margin-left: auto;
            display: flex;
            gap: 6px;
            opacity: 0;
            transition: opacity 0.15s;
        }
        .note-card:hover .note-card-actions {
            opacity: 1;
        }
        .note-card-actions:has(.confirming) {
            opacity: 1;
        }
        .note-card-actions:has(.confirming) .note-btn-edit {
            display: none;
        }
        .note-card:has(.note-edit-textarea) .note-card-actions {
            display: none;
        }
        .note-card-content {
            margin-top: 4px;
            font-size: 13px;
            line-height: 1.5;
            color: var(--fg);
        }
        .note-card-content.collapsed {
            max-height: 1.5em;
            overflow: hidden;
        }
        .note-expand-hint {
            display: block;
            font-size: 11px;
            color: \(textColorFaint);
            opacity: 0.5;
            margin-top: 2px;
            cursor: pointer;
        }
        .note-card.expanded .note-expand-hint { display: none; }

        /* Edit/delete buttons — match snapshot annotation style exactly */
        .note-card-actions button {
            background: none;
            border: none;
            color: \(textColor);
            cursor: pointer;
            font-size: 15px;
            padding: 3px 6px;
            border-radius: 4px;
            line-height: 1;
        }
        .note-card-actions button:hover {
            background: \(inputBg);
            color: var(--fg);
        }
        .note-card-actions .note-btn-delete {
            color: var(--delete-color);
        }
        .note-card-actions .note-btn-delete:hover {
            background: rgba(255, 59, 48, 0.1);
            color: var(--delete-color);
        }

        /* Delete confirmation — match snapshot style */
        .note-btn-delete.confirming {
            background: rgba(220, 40, 30, 0.75) !important;
            color: #fff !important;
            font-size: 12px;
            font-weight: 600;
            font-family: -apple-system, sans-serif;
            padding: 4px 12px !important;
            position: relative;
            overflow: hidden;
        }
        .note-btn-delete.confirming:hover {
            background: rgba(220, 40, 30, 0.85) !important;
            color: #fff !important;
        }
        .note-btn-delete.confirming::after {
            content: '';
            position: absolute;
            bottom: 0;
            left: 0;
            height: 1.5px;
            background: rgba(255, 255, 255, 0.8);
            animation: confirmDrain 5s linear forwards;
        }
        @keyframes confirmDrain {
            from { width: 100%; }
            to { width: 0%; }
        }

        /* Send bar */
        .send-bar {
            position: fixed;
            bottom: 0;
            left: 0;
            right: 0;
            height: 40px;
            background: \(sendBarBg);
            backdrop-filter: blur(8px);
            display: flex;
            align-items: center;
            justify-content: space-between;
            padding: 0 16px;
            color: white;
            font-family: -apple-system, system-ui, sans-serif;
            font-size: 13px;
            font-weight: 500;
            z-index: 1000;
            border-top: 1px solid \(sendBarBorderTop);
        }
        .send-bar-button {
            background: \(sendBtnBg);
            border: 1px solid \(sendBtnBorder);
            color: white;
            padding: 4px 12px;
            border-radius: 4px;
            cursor: pointer;
            font-weight: 600;
            font-size: 13px;
        }
        .send-bar-button:hover {
            background: rgba(255, 255, 255, 0.35);
        }

        /* Edit textarea in card */
        .note-edit-textarea {
            width: 100%;
            min-height: 36px;
            background: \(inputBg);
            border: 1px solid \(inputBorder);
            border-radius: 4px;
            color: var(--fg);
            font-family: -apple-system, system-ui, sans-serif;
            font-size: 13px;
            line-height: 1.4;
            padding: 6px 8px;
            resize: none;
            outline: none;
            box-sizing: border-box;
            margin-top: 6px;
        }
        .note-edit-textarea:focus {
            border-color: rgba(88, 166, 255, 0.5);
        }

        /* Emoji autocomplete popup — match snapshot reader exactly */
        .emoji-popup {
            position: absolute;
            z-index: 100;
            min-width: 200px;
            max-width: 340px;
            max-height: 300px;
            overflow-y: auto;
            background: \(formBg);
            border: 1px solid \(cardBorder);
            border-radius: 8px;
            box-shadow: 0 4px 12px rgba(0, 0, 0, 0.3);
            font-family: -apple-system, system-ui, sans-serif;
            font-size: 14px;
            padding: 4px 0;
            display: none;
        }
        .emoji-popup-row {
            display: flex;
            align-items: center;
            padding: 4px 10px;
            cursor: pointer;
            gap: 8px;
        }
        .emoji-popup-row.selected,
        .emoji-popup-row.selected:hover {
            background: rgba(88, 166, 255, 0.2);
        }
        .emoji-popup-row:hover {
            background: rgba(88, 166, 255, 0.12);
        }
        .emoji-popup-emoji {
            font-size: 18px;
            width: 24px;
            text-align: center;
            flex-shrink: 0;
        }
        .emoji-popup-name {
            color: var(--fg);
            overflow: hidden;
            text-overflow: ellipsis;
            white-space: nowrap;
        }
        .emoji-popup-name .emoji-match {
            font-weight: 600;
        }
        """
    }

    // MARK: - Note Manager JavaScript

    private static let noteManagerJS = """
    ScrollbackManager.notes = {
        items: [],
        nextNumber: 1,
        formElement: null,
        cardSpacers: {},
        editingId: null,
        expandedId: null,
        confirmingDeleteId: null,
        confirmDeleteTimer: null,
        highlightedLines: [],
        formStartLine: null,
        formEndLine: null,
        editIconSVG: '<svg width="1em" height="1em" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M17 3a2.828 2.828 0 114 4L7.5 20.5 2 22l1.5-5.5L17 3z"/></svg>',
        deleteIconSVG: '<svg width="1em" height="1em" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M3 6h18"/><path d="M8 6V4h8v2"/><path d="M5 6v14a1 1 0 001 1h12a1 1 0 001-1V6"/><path d="M10 11v6"/><path d="M14 11v6"/></svg>',

        initialize() {
            const self = this;

            // Drag-select detection
            document.addEventListener('mouseup', (e) => {
                // Ignore clicks on note UI elements
                if (e.target.closest('.note-form') ||
                    e.target.closest('.note-card') ||
                    e.target.closest('.send-bar')) return;

                const sel = window.getSelection();
                if (!sel || sel.isCollapsed) return;

                const range = sel.getRangeAt(0);
                const startLine = self.findLineElement(range.startContainer);
                const endLine = self.findLineElement(range.endContainer);

                if (!startLine || !endLine) return;

                const startIdx = parseInt(startLine.dataset.line);
                const endIdx = parseInt(endLine.dataset.line);

                self.showNoteForm(
                    Math.min(startIdx, endIdx),
                    Math.max(startIdx, endIdx)
                );

                sel.removeAllRanges();
            });

            // Send bar click
            document.getElementById('send-bar-button').addEventListener('click', () => {
                self.sendToClaude();
            });
        },

        findLineElement(node) {
            let el = node.nodeType === 3 ? node.parentElement : node;
            while (el && !el.classList.contains('tl')) {
                el = el.parentElement;
            }
            return el;
        },

        // --- Form Management ---

        showNoteForm(startLine, endLine) {
            this.clearHighlights();
            for (let i = startLine; i <= endLine; i++) {
                const line = document.querySelector('[data-line=\"' + i + '\"]');
                if (line) {
                    line.classList.add('note-highlight');
                    this.highlightedLines.push(line);
                }
            }

            if (!this.formElement) {
                this.createForm();
            }

            this.formStartLine = startLine;
            this.formEndLine = endLine;

            // Update header — match snapshot style: "Note #N: line N"
            const ref = this.formElement.querySelector('.note-form-ref');
            if (startLine === endLine) {
                ref.textContent = 'Note #' + this.nextNumber + ': line ' + (startLine + 1);
            } else {
                ref.textContent = 'Note #' + this.nextNumber + ': lines ' + (startLine + 1) + '\\u2013' + (endLine + 1);
            }

            this.positionForm(endLine);
            this.formElement.style.display = 'block';
            const ta = this.formElement.querySelector('textarea');
            ta.value = '';
            ta.style.height = 'auto';
            // Focus after layout so the browser has positioned the form
            requestAnimationFrame(() => {
                ta.focus();
            });
        },

        createForm() {
            this.formElement = document.createElement('div');
            this.formElement.className = 'note-form';
            this.formElement.innerHTML =
                '<div class="note-form-header">' +
                    '<span class="note-form-ref"></span>' +
                '</div>' +
                '<textarea class="note-textarea" ' +
                    'placeholder="Add annotation\\u2026 (\\u2318Enter to save \\u00b7 Esc to dismiss)" ' +
                    'rows="1"></textarea>';

            // Don't append to DOM yet — positionForm() will place it
            const self = this;
            const ta = this.formElement.querySelector('textarea');

            // Keyboard handling — emoji handleKeyDown must be first
            ta.addEventListener('keydown', (e) => {
                if (typeof EmojiAutocomplete !== 'undefined' &&
                    EmojiAutocomplete.handleKeyDown(ta, e)) {
                    return;
                }
                if (e.key === 'Enter' && e.metaKey) {
                    e.preventDefault();
                    self.submitNote();
                }
                // Don't let Escape propagate to ScrollbackManager.handleKey
                if (e.key === 'Escape') {
                    e.preventDefault();
                    e.stopPropagation();
                    self.handleFormEscape(ta);
                }
            });

            // Auto-grow/shrink textarea
            ta.addEventListener('input', () => {
                ta.style.height = 'auto';
                ta.style.height = ta.scrollHeight + 'px';
            });

            // Attach emoji autocomplete
            if (typeof EmojiAutocomplete !== 'undefined') {
                EmojiAutocomplete.attach(ta);
            }
        },

        handleFormEscape(ta) {
            // Check emoji popup first
            if (typeof EmojiAutocomplete !== 'undefined' &&
                EmojiAutocomplete.isActive(ta)) {
                EmojiAutocomplete.dismiss(ta);
                return;
            }
            if (ta.value.length > 0) {
                ta.value = '';
                ta.style.height = 'auto';
                } else {
                this.hideForm();
                this.clearHighlights();
            }
        },

        positionForm(endLine) {
            // Remove form from current position
            if (this.formElement.parentNode) {
                this.formElement.remove();
            }

            const endLineEl = document.querySelector('[data-line=\"' + endLine + '\"]');
            if (!endLineEl) return;

            // Insert form in flow after end line (after any existing cards)
            const insertPoint = this.findInsertPoint(endLineEl);
            insertPoint.after(this.formElement);
        },

        hideForm() {
            if (this.formElement) {
                this.formElement.style.display = 'none';
            }
        },

        submitNote() {
            const ta = this.formElement.querySelector('textarea');
            const content = ta.value.trim();
            if (!content) return;

            // Extract line content from DOM
            let lineContent = '';
            for (let i = this.formStartLine; i <= this.formEndLine; i++) {
                const line = document.querySelector('[data-line=\"' + i + '\"]');
                if (line) {
                    if (lineContent) lineContent += '\\n';
                    lineContent += line.textContent;
                }
            }

            // Post to Swift
            window.webkit.messageHandlers.scrollback.postMessage({
                action: 'createNote',
                startLine: this.formStartLine,
                endLine: this.formEndLine,
                lineContent: lineContent,
                content: content
            });

            // Clear form
            ta.value = '';
            ta.style.height = 'auto';
            this.hideForm();
            this.clearHighlights();
        },

        // --- Card Management ---

        noteCreated(note) {
            // Assign number if not present
            if (!note.number) {
                note.number = this.nextNumber;
            }
            this.nextNumber = Math.max(this.nextNumber, note.number + 1);

            // Check for duplicate (from restoreNoteState)
            if (this.items.find(n => n.id === note.id)) return;

            this.items.push(note);
            this.insertCard(note);
            this.updateSendBar();
        },

        noteUpdated(note) {
            const idx = this.items.findIndex(n => n.id === note.id);
            if (idx >= 0) {
                this.items[idx].content = note.content;
            }
            // Update card content display (use innerHTML for <br> newlines)
            const card = document.querySelector('[data-note-id=\"' + note.id + '\"]');
            if (card) {
                const contentEl = card.querySelector('.note-card-content');
                if (contentEl) {
                    contentEl.innerHTML = this.escapeHTML(note.content);
                }
            }
            this.editingId = null;
        },

        noteDeleted(id) {
            this.items = this.items.filter(n => n.id !== id);

            // Remove card
            const entry = this.cardSpacers[id];
            if (entry) {
                if (entry.card) entry.card.remove();
                delete this.cardSpacers[id];
            }

            // Clear expanded state if this was expanded
            if (this.expandedId === id) {
                this.expandedId = null;
                this.clearExpandHighlights();
            }

            this.updateSendBar();
        },

        insertCard(note) {
            const endLineEl = document.querySelector('[data-line=\"' + note.endLine + '\"]');
            if (!endLineEl) return;

            // Create card in flow after end line (after existing cards)
            const card = this.buildCardElement(note);
            const insertPoint = this.findInsertPoint(endLineEl);
            insertPoint.after(card);

            this.cardSpacers[note.id] = { card: card };
        },

        buildCardElement(note) {
            const self = this;
            const card = document.createElement('div');
            card.className = 'note-card';
            card.dataset.noteId = note.id;

            const refText = note.startLine === note.endLine
                ? 'Line ' + (note.startLine + 1)
                : 'Lines ' + (note.startLine + 1) + '–' + (note.endLine + 1);

            card.innerHTML =
                '<div class="note-card-header">' +
                    '<span class="note-card-ref">' + refText + '</span>' +
                    '<span class="note-card-meta">#' + note.number + '</span>' +
                    '<span class="note-card-actions">' +
                        '<button class="note-btn-edit" title="Edit">' +
                            self.editIconSVG + '</button>' +
                        '<button class="note-btn-delete" title="Delete">' +
                            self.deleteIconSVG + '</button>' +
                    '</span>' +
                '</div>' +
                '<div class="note-card-content collapsed">' +
                    self.escapeHTML(note.content) +
                '</div>' +
                '<span class="note-expand-hint">Click to expand</span>';

            // Click to expand/collapse
            card.addEventListener('click', (e) => {
                if (e.target.closest('.note-btn-edit') ||
                    e.target.closest('.note-btn-delete') ||
                    e.target.closest('.note-edit-textarea')) return;
                self.toggleExpand(note.id);
            });

            // Edit button
            card.querySelector('.note-btn-edit').addEventListener('click', (e) => {
                e.stopPropagation();
                self.startEdit(note.id);
            });

            // Delete button
            card.querySelector('.note-btn-delete').addEventListener('click', (e) => {
                e.stopPropagation();
                self.handleDelete(note.id);
            });

            return card;
        },

        // --- Expand/Collapse ---

        toggleExpand(noteId) {
            if (this.editingId) return;

            const card = document.querySelector('[data-note-id=\"' + noteId + '\"]');
            if (!card) return;
            const contentEl = card.querySelector('.note-card-content');

            if (this.expandedId === noteId) {
                // Collapse
                card.classList.remove('expanded');
                if (contentEl) contentEl.classList.add('collapsed');
                this.expandedId = null;
                this.clearExpandHighlights();
            } else {
                // Collapse previous
                if (this.expandedId) {
                    const prev = document.querySelector('[data-note-id=\"' + this.expandedId + '\"]');
                    if (prev) {
                        prev.classList.remove('expanded');
                        const prevContent = prev.querySelector('.note-card-content');
                        if (prevContent) prevContent.classList.add('collapsed');
                    }
                    this.clearExpandHighlights();
                }

                // Expand this — yellow border on card, show full content,
                // yellow highlight on referenced lines
                card.classList.add('expanded');
                if (contentEl) contentEl.classList.remove('collapsed');
                this.expandedId = noteId;

                const note = this.items.find(n => n.id === noteId);
                if (note) {
                    for (let i = note.startLine; i <= note.endLine; i++) {
                        const line = document.querySelector('[data-line=\"' + i + '\"]');
                        if (line) line.classList.add('note-expanded-highlight');
                    }
                }
            }
        },

        clearExpandHighlights() {
            document.querySelectorAll('.note-expanded-highlight').forEach(el => {
                el.classList.remove('note-expanded-highlight');
            });
        },

        // --- Edit ---

        startEdit(noteId) {
            const note = this.items.find(n => n.id === noteId);
            if (!note) return;

            const card = document.querySelector('[data-note-id=\"' + noteId + '\"]');
            if (!card) return;

            // Expand if not already
            if (this.expandedId !== noteId) {
                this.toggleExpand(noteId);
            }

            this.editingId = noteId;

            // Replace content with textarea
            const contentEl = card.querySelector('.note-card-content');
            const originalContent = note.content;
            contentEl.innerHTML = '';
            contentEl.classList.remove('collapsed');

            const ta = document.createElement('textarea');
            ta.className = 'note-edit-textarea';
            ta.value = originalContent;
            ta.rows = 2;
            contentEl.appendChild(ta);

            // Auto-size
            ta.style.height = 'auto';
            ta.style.height = ta.scrollHeight + 'px';

            const self = this;

            ta.addEventListener('keydown', (e) => {
                if (typeof EmojiAutocomplete !== 'undefined' &&
                    EmojiAutocomplete.handleKeyDown(ta, e)) {
                    return;
                }
                if (e.key === 'Enter' && e.metaKey) {
                    e.preventDefault();
                    self.saveEdit(noteId, ta.value);
                }
                if (e.key === 'Escape') {
                    e.preventDefault();
                    e.stopPropagation();
                    self.cancelEdit(noteId, originalContent);
                }
            });

            ta.addEventListener('input', () => {
                ta.style.height = 'auto';
                ta.style.height = ta.scrollHeight + 'px';
            });

            // Attach emoji autocomplete
            if (typeof EmojiAutocomplete !== 'undefined') {
                EmojiAutocomplete.attach(ta);
            }

            ta.focus();
        },

        saveEdit(noteId, newContent) {
            const trimmed = newContent.trim();
            if (!trimmed) return;

            window.webkit.messageHandlers.scrollback.postMessage({
                action: 'updateNote',
                id: noteId,
                content: trimmed
            });
        },

        cancelEdit(noteId, originalContent) {
            this.editingId = null;
            const card = document.querySelector('[data-note-id=\"' + noteId + '\"]');
            if (!card) return;

            const contentEl = card.querySelector('.note-card-content');
            contentEl.innerHTML = '';
            contentEl.textContent = originalContent;
        },

        // --- Delete ---

        handleDelete(noteId) {
            if (this.confirmingDeleteId === noteId) {
                // Second click — confirm delete
                clearTimeout(this.confirmDeleteTimer);
                this.confirmingDeleteId = null;
                this.confirmDeleteTimer = null;

                window.webkit.messageHandlers.scrollback.postMessage({
                    action: 'deleteNote',
                    id: noteId
                });
                return;
            }

            // First click — show confirmation
            this.confirmingDeleteId = noteId;
            const card = document.querySelector('[data-note-id=\"' + noteId + '\"]');
            if (!card) return;

            const btn = card.querySelector('.note-btn-delete');
            btn.classList.add('confirming');
            btn.textContent = 'Are you sure?';

            const self = this;
            this.confirmDeleteTimer = setTimeout(() => {
                btn.classList.remove('confirming');
                btn.innerHTML = self.deleteIconSVG;
                self.confirmingDeleteId = null;
                self.confirmDeleteTimer = null;
            }, 5000);
        },

        // --- Highlight Management ---

        clearHighlights() {
            this.highlightedLines.forEach(el => {
                el.classList.remove('note-highlight');
            });
            this.highlightedLines = [];
        },

        // --- Position Sync ---

        findInsertPoint(lineEl) {
            // Walk siblings after the line to find the last card/form,
            // so new items stack after existing ones
            let point = lineEl;
            let next = point.nextElementSibling;
            while (next && (next.classList.contains('note-card') ||
                            next.classList.contains('note-form'))) {
                point = next;
                next = point.nextElementSibling;
            }
            return point;
        },

        // --- Send Bar ---

        updateSendBar() {
            const bar = document.getElementById('send-bar');
            const count = document.getElementById('send-bar-count');
            if (this.items.length > 0) {
                bar.style.display = 'flex';
                const n = this.items.length;
                count.textContent = n + ' note' + (n === 1 ? '' : 's');
            } else {
                bar.style.display = 'none';
            }
        },

        sendToClaude() {
            if (this.items.length === 0) return;

            const sorted = [...this.items].sort((a, b) => a.startLine - b.startLine);
            const message = sorted.map(note => {
                return '```\\n' + note.lineContent + '\\n```\\n' + note.content;
            }).join('\\n\\n');

            window.webkit.messageHandlers.scrollback.postMessage({
                action: 'sendToClaude',
                message: message
            });
        },

        // --- Utilities ---

        escapeHTML(str) {
            const div = document.createElement('div');
            div.textContent = str;
            return div.innerHTML.replace(/\\n/g, '<br>');
        }
    };
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
