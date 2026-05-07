import Foundation

/// CSS for verbatim text rendering inside annotation/note card
/// bodies. Targets `.verbatim-card-content`, the marker class
/// applied to every card-style container that displays user-typed
/// note/annotation text.
///
/// Notes and annotations render exactly as typed — no markdown,
/// no auto-linking. `white-space: pre-wrap` preserves newlines
/// and runs of whitespace. `overflow-wrap: anywhere` keeps long
/// unbreakable strings (URLs, paths, hashes) from blowing past
/// the card width. The mono font matches the textarea the user
/// typed into and makes pasted indented/tabular content align.
///
/// Single source of truth: scrollback notes and artifact +
/// snapshot annotations apply identical rules so the card display
/// matches the edit textarea byte-for-byte.
let verbatimCardCSS: String = """
    .verbatim-card-content {
        white-space: pre-wrap;
        overflow-wrap: anywhere;
        font-family: var(--font-family-mono);
    }
"""
