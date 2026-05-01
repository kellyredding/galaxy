import Foundation
import SwiftUI

/// A run of text with its rendered attributes. The parser
/// produces a flat array of these chunks for one input line;
/// the view composes them into a single colored Text.
struct StatuslineANSIChunk: Equatable {
    let text: String
    let foreground: Color?
    let bold: Bool
}

/// Minimal ANSI escape-sequence parser for the subset of codes
/// the galaxy-statusline CLI emits via Colors.colorize:
///
///   31..37   basic foreground (red, green, yellow, blue,
///            magenta, cyan, white)
///   91..97   bright foreground (same order, bright variants)
///   1        bold
///   0        reset everything
///
/// Other codes are silently ignored. Newlines split the input
/// into separate lines; chunks within a line preserve the
/// colors and bold flag set by the most recent escape sequence.
enum StatuslineANSIParser {
    static func parse(_ input: String) -> [[StatuslineANSIChunk]] {
        var lines: [[StatuslineANSIChunk]] = []
        var currentLine: [StatuslineANSIChunk] = []
        var currentText = ""
        var fg: Color? = nil
        var bold = false

        let scalars = Array(input.unicodeScalars)
        var i = 0

        func flushChunk() {
            if !currentText.isEmpty {
                currentLine.append(
                    StatuslineANSIChunk(
                        text: currentText, foreground: fg, bold: bold
                    )
                )
                currentText = ""
            }
        }

        func flushLine() {
            flushChunk()
            lines.append(currentLine)
            currentLine = []
        }

        while i < scalars.count {
            let s = scalars[i]

            // ANSI escape: ESC [ ... m
            if s.value == 0x1B,
               i + 1 < scalars.count,
               scalars[i + 1] == "[" {
                flushChunk()
                // Walk until 'm' (or end of input)
                var j = i + 2
                var paramText = ""
                while j < scalars.count && scalars[j] != "m" {
                    paramText.unicodeScalars.append(scalars[j])
                    j += 1
                }
                // Apply codes
                if j < scalars.count {
                    let codes = paramText
                        .split(separator: ";")
                        .compactMap { Int($0) }
                    if codes.isEmpty || codes == [0] {
                        fg = nil
                        bold = false
                    } else {
                        for code in codes {
                            switch code {
                            case 0:
                                fg = nil
                                bold = false
                            case 1:
                                bold = true
                            case 30...37:
                                fg = Self.basicColor(code - 30)
                            case 90...97:
                                fg = Self.brightColor(code - 90)
                            case 39:
                                // Default foreground
                                fg = nil
                            default:
                                break
                            }
                        }
                    }
                    i = j + 1
                } else {
                    // Unterminated escape — treat the ESC as literal
                    currentText.append(Character(s))
                    i += 1
                }
                continue
            }

            // Newline — split into a new line
            if s == "\n" {
                flushLine()
                i += 1
                continue
            }

            currentText.append(Character(s))
            i += 1
        }

        flushChunk()
        if !currentLine.isEmpty {
            lines.append(currentLine)
        }
        return lines
    }

    /// Index 0..7 → black, red, green, yellow, blue, magenta,
    /// cyan, white. Returns the SwiftUI Color used to approximate
    /// the basic ANSI palette in the preview pane. Black returns
    /// nil so it falls through to the system text color, which is
    /// readable on both light and dark backgrounds.
    private static func basicColor(_ index: Int) -> Color? {
        switch index {
        case 0: return nil              // black — defer to text color
        case 1: return .red
        case 2: return .green
        case 3: return .yellow
        case 4: return .blue
        case 5: return .pink            // magenta
        case 6: return .cyan
        case 7: return .white
        default: return nil
        }
    }

    /// Bright variants — slightly higher saturation/brightness so
    /// the user can tell which half of the palette they picked.
    /// SwiftUI's named colors don't include "bright" variants, so
    /// we mix bright tones manually. Index 0 (bright black) returns
    /// nil to fall through to the system text color.
    private static func brightColor(_ index: Int) -> Color? {
        switch index {
        case 0: return nil                                        // bright black
        case 1: return Color(red: 1.0, green: 0.40, blue: 0.40)   // bright red
        case 2: return Color(red: 0.45, green: 1.0, blue: 0.45)   // bright green
        case 3: return Color(red: 1.0, green: 0.95, blue: 0.45)   // bright yellow
        case 4: return Color(red: 0.45, green: 0.65, blue: 1.0)   // bright blue
        case 5: return Color(red: 1.0, green: 0.55, blue: 0.85)   // bright magenta
        case 6: return Color(red: 0.45, green: 0.95, blue: 1.0)   // bright cyan
        case 7: return .white
        default: return nil
        }
    }
}

extension StatuslineANSIChunk {
    /// Build a styled Text fragment for this chunk. Caller should
    /// concatenate with `+` to build a single Text per line.
    func styledText() -> Text {
        var t = Text(text)
        if let fg = foreground { t = t.foregroundColor(fg) }
        if bold { t = t.bold() }
        return t
    }
}
