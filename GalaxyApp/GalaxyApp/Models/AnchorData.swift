import Foundation
import Galactic

/// Typed representation of an artifact annotation's
/// anchor_data JSON. Supports multiple anchor types
/// for different content renderers.
struct AnchorData: Codable {
    let type: ReaderAnchorType

    // line_range fields
    let startLine: Int32?
    let endLine: Int32?
    let lineContent: String?

    // row_range fields
    let startRow: Int32?
    let endRow: Int32?
    let rowContent: String?

    // block_range fields
    let startBlock: Int32?
    let endBlock: Int32?
    let blockContent: String?

    // whole fields
    let artifactPath: String?

    // diff_range extras — structured file + per-file line
    // info captured alongside the global `start_line` /
    // `end_line` data-line counter. Optional for
    // backward compatibility with annotations captured
    // before these fields existed (those fall back to
    // the global-line display in the JS renderer).
    let filePath: String?
    let fileStartLine: Int32?
    let fileEndLine: Int32?
    /// "new" when the range lands on add/context/modified
    /// rows (the line number references the file's new
    /// side); "old" when the range is entirely on delete
    /// rows (line number references the old side).
    let fileLineSide: String?

    /// The selected rows as plain source, with no diff
    /// markers.
    ///
    /// `lineContent` prefixes each row with `+ `, `- `, or
    /// two spaces so a reviewing agent can tell additions
    /// from deletions from context. That is the wrong text
    /// to put on the clipboard or inside a suggestion
    /// block, which want code that could be pasted back
    /// into the file. Both forms are recorded rather than
    /// one being derived from the other, because stripping
    /// a prefix would corrupt any line whose own code
    /// begins with those characters.
    ///
    /// Absent on annotations written before this existed;
    /// those fall back to reconstructing it from the
    /// rendered rows.
    let sourceContent: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(
            keyedBy: CodingKeys.self
        )
        type = try container.decode(
            ReaderAnchorType.self, forKey: .type
        )
        startLine = try container.decodeIfPresent(
            Int32.self, forKey: .startLine
        )
        endLine = try container.decodeIfPresent(
            Int32.self, forKey: .endLine
        )
        lineContent = try container.decodeIfPresent(
            String.self, forKey: .lineContent
        )
        startRow = try container.decodeIfPresent(
            Int32.self, forKey: .startRow
        )
        endRow = try container.decodeIfPresent(
            Int32.self, forKey: .endRow
        )
        rowContent = try container.decodeIfPresent(
            String.self, forKey: .rowContent
        )
        startBlock = try container.decodeIfPresent(
            Int32.self, forKey: .startBlock
        )
        endBlock = try container.decodeIfPresent(
            Int32.self, forKey: .endBlock
        )
        blockContent = try container.decodeIfPresent(
            String.self, forKey: .blockContent
        )
        artifactPath = try container.decodeIfPresent(
            String.self, forKey: .artifactPath
        )
        filePath = try container.decodeIfPresent(
            String.self, forKey: .filePath
        )
        fileStartLine = try container.decodeIfPresent(
            Int32.self, forKey: .fileStartLine
        )
        fileEndLine = try container.decodeIfPresent(
            Int32.self, forKey: .fileEndLine
        )
        fileLineSide = try container.decodeIfPresent(
            String.self, forKey: .fileLineSide
        )
        sourceContent = try container.decodeIfPresent(
            String.self, forKey: .sourceContent
        )
    }

    /// Content captured at annotation time, regardless
    /// of anchor type.
    var capturedContent: String? {
        lineContent ?? rowContent ?? blockContent
    }
}

