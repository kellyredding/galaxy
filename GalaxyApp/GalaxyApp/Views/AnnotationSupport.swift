import Foundation
import WebKit
import Galactic

// MARK: - Emoji Data / Autocomplete JS

// Names kept for the readers that interpolate them; the loading moved. Both
// files now ship with the card UI that depends on them rather than with each
// app, which is also what retired the second copy of this loader that used to
// sit inside the scrollback renderer.
let emojiDataJS: String = EmojiJS.data
let emojiAutocompleteJS: String = EmojiJS.autocomplete

/// Overload for `[ArtifactAnnotation]` — maps anchor-type
/// variants (line_range / row_range / block_range / whole)
/// into the flat dict shape the JS expects.
func buildAnnotationInitJS(
    anchorType: String,
    blockSelector: String,
    lineAttr: String,
    endLineAttr: String? = nil,
    refPrefix: String,
    itemLabel: String,
    annotations: [ArtifactAnnotation],
    htmlMap: [Int32: String],
    artifactContent: String? = nil,
    referencePath: String? = nil
) -> String {
    let dicts: [[String: Any]] = annotations.map {
        annotationDict($0)
    }
    return buildAnnotationInitJS(
        anchorType: anchorType,
        blockSelector: blockSelector,
        lineAttr: lineAttr,
        endLineAttr: endLineAttr,
        refPrefix: refPrefix,
        itemLabel: itemLabel,
        annotationDicts: dicts,
        htmlMap: htmlMap,
        artifactContent: artifactContent,
        referencePath: referencePath,
        // Supplied here rather than read inside the shared builder. The
        // bindings are a global setting rather than per-reader data, and each
        // app keeps them in a settings type of its own — reading one from
        // shared code would tie it to this app.
        textEntry: SettingsManager.shared.settings.textEntry.jsPayload
    )
}

/// Flatten one annotation into the shape the page reads.
///
/// The single answer to that question. It used to be answered twice —
/// once when a reader loads and once when its cards are rebuilt — and
/// the two drifted every time one learned something the other did
/// not: card bodies, captured source text, and the per-file reference
/// a diff annotation carries, each missing from the rebuilt form until
/// someone noticed a card that had gone quiet.
func annotationDict(
    _ a: ArtifactAnnotation
) -> [String: Any] {
    var dict: [String: Any] = [
        "id": a.id,
        "number": a.number,
        "content": a.content,
        "created_at": a.createdAt,
        "updated_at": a.updatedAt,
    ]
    switch a.anchorData.type {
    case .lineRange:
        if let sl = a.anchorData.startLine {
            dict["start_line"] = sl
        }
        if let el = a.anchorData.endLine {
            dict["end_line"] = el
        }
        if let lc = a.anchorData.lineContent {
            dict["line_content"] = lc
        }
    case .diffRange:
        // Keep the global data-line values —
        // DOM anchoring still uses them — and
        // also emit the per-file reference so
        // the JS renderer can show a friendlier
        // label (`path/to/file.rb:N`) and the
        // file-collapse handler can match cards
        // by path.
        if let sl = a.anchorData.startLine {
            dict["start_line"] = sl
        }
        if let el = a.anchorData.endLine {
            dict["end_line"] = el
        }
        if let lc = a.anchorData.lineContent {
            dict["line_content"] = lc
        }
        // The unmarked form, for the clipboard and for
        // suggestions. Absent on older annotations, which
        // fall back to rebuilding it from the rendered rows.
        if let sc = a.anchorData.sourceContent {
            dict["source_content"] = sc
        }
        if let fp = a.anchorData.filePath {
            dict["file_path"] = fp
        }
        if let fs = a.anchorData.fileStartLine {
            dict["file_start_line"] = fs
        }
        if let fe = a.anchorData.fileEndLine {
            dict["file_end_line"] = fe
        }
        if let fls = a.anchorData.fileLineSide {
            dict["file_line_side"] = fls
        }
    case .rowRange:
        if let sr = a.anchorData.startRow {
            dict["start_row"] = sr
        }
        if let er = a.anchorData.endRow {
            dict["end_row"] = er
        }
        if let rc = a.anchorData.rowContent {
            dict["row_content"] = rc
        }
    case .blockRange:
        if let sb = a.anchorData.startBlock {
            dict["start_block"] = sb
        }
        if let eb = a.anchorData.endBlock {
            dict["end_block"] = eb
        }
        if let bc = a.anchorData.blockContent {
            dict["block_content"] = bc
        }
    case .whole:
        break
    }
    if let rn = a.reviewNumber {
        dict["review_number"] = rn
    }
    if let rra = a.reviewReviewedAt {
        dict["review_reviewed_at"] = rra
    }
    return dict
}

/// Which annotations belong on a given reader.
///
/// Named once so that the initial load and any later rebuild cannot
/// answer the question differently. They did: the rebuild applied one
/// blanket rule to every reader, which excluded whole-file anchors —
/// exactly the annotations a whole-file reader exists to show, and
/// none of the ones it does not. Refreshing a diagram inverted its
/// cards.
struct AnnotationScope {
    /// Anchor types the reader can place, or nil when it screens
    /// nothing and shows whatever it is handed.
    private let accepted: Set<AnchorType>?

    private init(_ accepted: Set<AnchorType>?) {
        self.accepted = accepted
    }

    func accepts(_ type: AnchorType) -> Bool {
        guard let accepted else { return true }
        return accepted.contains(type)
    }

    static let lineRange = AnnotationScope([.lineRange])
    static let rowRange = AnnotationScope([.rowRange])
    static let blockRange = AnnotationScope([.blockRange])

    /// The diff reader is told `line_range`, since its rows carry the
    /// `data-line` attributes the page resolves the usual way, but its
    /// annotations are written as `diff_range` so they can also record
    /// a per-file reference. Both kinds belong to it, which is why a
    /// rule derived from what the page is told would drop half of
    /// them.
    static let diff = AnnotationScope([.lineRange, .diffRange])

    /// Whole-file readers screen nothing. An annotation they cannot
    /// place is still worth showing: it counts toward the review
    /// button either way, and hiding it would leave pending work with
    /// nowhere to appear. Same reasoning as the stale drawer.
    static let unscreened = AnnotationScope(nil)
}

/// A line-range annotation, whichever store it came from.
///
/// Artifacts and snapshots describe the same idea differently: one
/// keeps the range inside an anchor payload and records the source
/// text captured when the annotation was written, the other keeps the
/// range in dedicated columns and captures nothing. Reading both
/// through one shape lets the markdown reader serve either without an
/// artifact annotation being flattened into a snapshot one first,
/// which used to discard the captured text on the way.
protocol LineRangeAnnotation {
    var id: Int64 { get }
    var number: Int32 { get }
    var content: String { get }
    var createdAt: String { get }
    var updatedAt: String { get }
    var reviewNumber: Int32? { get }
    var reviewReviewedAt: String? { get }
    var anchorStartLine: Int32? { get }
    var anchorEndLine: Int32? { get }
    var anchorLineContent: String? { get }
}

extension ArtifactAnnotation: LineRangeAnnotation {
    var anchorStartLine: Int32? { anchorData.startLine }
    var anchorEndLine: Int32? { anchorData.endLine }
    var anchorLineContent: String? { anchorData.lineContent }
}

extension SnapshotAnnotation: LineRangeAnnotation {
    var anchorStartLine: Int32? { startLine }
    var anchorEndLine: Int32? { endLine }
    /// Snapshots have no column for captured text, so the reader
    /// slices the source instead. Safe there because snapshot
    /// content cannot change under an annotation.
    var anchorLineContent: String? { nil }
}

/// Overload for line-range annotations from either store — the dict
/// shape is simpler than the artifact variant, which also has to
/// carry row, block, and whole-file anchors.
func buildAnnotationInitJS(
    anchorType: String,
    blockSelector: String,
    lineAttr: String,
    endLineAttr: String? = nil,
    refPrefix: String,
    itemLabel: String,
    annotations: [any LineRangeAnnotation],
    htmlMap: [Int32: String],
    artifactContent: String? = nil,
    referencePath: String? = nil
) -> String {
    let dicts: [[String: Any]] = annotations.map { a in
        var dict: [String: Any] = [
            "id": a.id,
            "number": a.number,
            "content": a.content,
            "created_at": a.createdAt,
            "updated_at": a.updatedAt,
        ]
        if let sl = a.anchorStartLine {
            dict["start_line"] = sl
        }
        if let el = a.anchorEndLine {
            dict["end_line"] = el
        }
        if let lc = a.anchorLineContent {
            dict["line_content"] = lc
        }
        if let rn = a.reviewNumber {
            dict["review_number"] = rn
        }
        if let rra = a.reviewReviewedAt {
            dict["review_reviewed_at"] = rra
        }
        return dict
    }

    return buildAnnotationInitJS(
        anchorType: anchorType,
        blockSelector: blockSelector,
        lineAttr: lineAttr,
        endLineAttr: endLineAttr,
        refPrefix: refPrefix,
        itemLabel: itemLabel,
        annotationDicts: dicts,
        htmlMap: htmlMap,
        artifactContent: artifactContent,
        referencePath: referencePath,
        // Supplied here rather than read inside the shared builder. The
        // bindings are a global setting rather than per-reader data, and each
        // app keeps them in a settings type of its own — reading one from
        // shared code would tie it to this app.
        textEntry: SettingsManager.shared.settings.textEntry.jsPayload
    )
}
