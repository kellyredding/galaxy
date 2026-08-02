import Foundation
import Galactic

// MARK: - Emoji Data / Autocomplete JS

/// Names the reader HTML templates interpolate. The data itself ships with
/// the engine; these exist so the templates read the same as they did when
/// the files were Galaxy's.
let emojiDataJS: String = EmojiJS.data
let emojiAutocompleteJS: String = EmojiJS.autocomplete

// MARK: - Reader annotation conformances

/// Both stores read through the engine's one annotation shape.
///
/// Artifacts and snapshots describe the same idea differently: one keeps the
/// range inside an anchor payload and records the source text captured when
/// the annotation was written, the other keeps the range in dedicated columns
/// and captures nothing. Conforming both lets any reader serve either without
/// one being flattened into the other first, which is how captured text used
/// to get discarded on the way in.
extension ArtifactAnnotation: ReaderAnnotation {
    var isStale: Bool { stale }
    var anchorType: ReaderAnchorType { anchorData.type }

    var anchorStartLine: Int32? { anchorData.startLine }
    var anchorEndLine: Int32? { anchorData.endLine }
    var anchorLineContent: String? { anchorData.lineContent }

    var anchorStartRow: Int32? { anchorData.startRow }
    var anchorEndRow: Int32? { anchorData.endRow }
    var anchorRowContent: String? { anchorData.rowContent }

    var anchorStartBlock: Int32? { anchorData.startBlock }
    var anchorEndBlock: Int32? { anchorData.endBlock }
    var anchorBlockContent: String? { anchorData.blockContent }

    var anchorSourceContent: String? { anchorData.sourceContent }

    var anchorFilePath: String? { anchorData.filePath }
    var anchorFileStartLine: Int32? { anchorData.fileStartLine }
    var anchorFileEndLine: Int32? { anchorData.fileEndLine }
    var anchorFileLineSide: String? { anchorData.fileLineSide }

    var anchorDocumentPath: String? { anchorData.artifactPath }
}

extension SnapshotAnnotation: ReaderAnnotation {
    /// Snapshots only ever anchor by line.
    var anchorType: ReaderAnchorType { .lineRange }

    var anchorStartLine: Int32? { startLine }
    var anchorEndLine: Int32? { endLine }
    /// Snapshots have no column for captured text, so the reader slices the
    /// source instead. Safe there, because snapshot content cannot change
    /// under an annotation — which is also why `isStale` keeps its default of
    /// false rather than being answered from a column that does not exist.
    var anchorLineContent: String? { nil }
}

// MARK: - Init JS

/// Hand a reader's annotation state to the page, with this app's composer
/// bindings attached.
///
/// The engine's builder takes `textEntry` as a parameter rather than reading
/// it, because the bindings are a global setting rather than per-reader data
/// and each app keeps them in a settings type of its own. This is where Galaxy
/// answers that — one place, so a reader never reaches for the singleton
/// itself.
func buildAnnotationInitJS(
    anchoring: ReaderAnchoring,
    itemLabel: String,
    annotations: [any ReaderAnnotation],
    htmlMap: [Int32: String],
    artifactContent: String? = nil,
    referencePath: String? = nil
) -> String {
    buildAnnotationInitJS(
        anchoring: anchoring,
        itemLabel: itemLabel,
        annotations: annotations,
        htmlMap: htmlMap,
        artifactContent: artifactContent,
        referencePath: referencePath,
        textEntry: SettingsManager.shared.settings.textEntry.jsPayload
    )
}
