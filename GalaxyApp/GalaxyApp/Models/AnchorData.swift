import Foundation

/// Typed representation of an artifact annotation's
/// anchor_data JSON. Supports multiple anchor types
/// for different content renderers.
struct AnchorData: Codable {
    let type: AnchorType

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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(
            keyedBy: CodingKeys.self
        )
        type = try container.decode(
            AnchorType.self, forKey: .type
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
    }

    /// Content captured at annotation time, regardless
    /// of anchor type.
    var capturedContent: String? {
        lineContent ?? rowContent ?? blockContent
    }
}

enum AnchorType: String, Codable {
    case lineRange = "line_range"
    case rowRange = "row_range"
    case blockRange = "block_range"
    case diffRange = "diff_range"
    case whole = "whole"
}
