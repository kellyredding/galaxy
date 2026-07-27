import Foundation

// MARK: - Shared JS-side text-entry matcher
//
// Defines `window.GalaxyTextEntry`, the WebView twin of the Swift
// `TextEntryBindings` resolver. Any WKWebView module with a composer
// textarea — scrollback notes, annotation forms — asks it whether a
// keydown commits, inserts a newline, or is none of its business.
//
// Two things keep it honest against the Swift side:
//
//   1. The modifier bitmask is shared verbatim. The bit positions
//      below are the same ones `Keystroke.Modifiers` uses.
//   2. Bindings arrive keyed by DOM `code` strings, because a WebView
//      never sees a macOS virtual key code. Swift translates through
//      `Keystroke.domCode` when it injects the configuration, so no
//      key table lives on this side.
//
// `fixtures/text-entry-cases.json` pins both, and
// `scripts/verify-text-entry.mjs` runs this literal against it. A
// disagreement between the two matchers fails the build rather than
// surfacing months later as a key that quietly stopped working.
//
// Inject before any module that calls into `GalaxyTextEntry`.
// Idempotent — a second injection is a no-op.

// js-validate
let textEntryJS: String = """
(function() {
    if (window.GalaxyTextEntry) return;

    // Must match Keystroke.Modifiers on the Swift side.
    var MOD_COMMAND = 1;
    var MOD_OPTION = 2;
    var MOD_CONTROL = 4;
    var MOD_SHIFT = 8;

    var bindings = { submit: [], newline: [] };

    // Caps-lock, fn, and the numeric-pad flag are deliberately not read,
    // which is how this stays in step with the normalisation
    // Modifiers.init(deviceFlags:) performs on the Swift side. Incidental
    // modifier state must never decide whether a binding matches.
    function modifiersOf(e) {
        var m = 0;
        if (e.metaKey) m |= MOD_COMMAND;
        if (e.altKey) m |= MOD_OPTION;
        if (e.ctrlKey) m |= MOD_CONTROL;
        if (e.shiftKey) m |= MOD_SHIFT;
        return m;
    }

    function matches(list, code, mods) {
        if (!list) return false;
        for (var i = 0; i < list.length; i++) {
            if (list[i].code === code && list[i].modifiers === mods) {
                return true;
            }
        }
        return false;
    }

    window.GalaxyTextEntry = {
        // cfg: { submit: [{code, modifiers}], newline: [{code, modifiers}] }
        configure: function (cfg) {
            bindings = {
                submit: (cfg && cfg.submit) || [],
                newline: (cfg && cfg.newline) || []
            };
        },

        // Returns 'submit' | 'newline' | null.
        //
        // Null means "not ours" and the caller MUST let the event through
        // untouched. Swallowing it would break every key the app does not
        // own, which is most of them.
        //
        // Submit is tested first, so a keystroke present in both lists
        // commits — the same tie-break the Swift resolver makes.
        actionFor: function (e) {
            var mods = modifiersOf(e);
            if (matches(bindings.submit, e.code, mods)) return 'submit';
            if (matches(bindings.newline, e.code, mods)) return 'newline';
            return null;
        },

        // handlers: { submit: fn, newline: fn } — either may be omitted, in
        // which case that action falls through to the browser's default.
        bind: function (textarea, handlers) {
            textarea.addEventListener('keydown', function (e) {
                var action = window.GalaxyTextEntry.actionFor(e);
                if (!action) return;
                var handler = handlers && handlers[action];
                if (!handler) return;
                e.preventDefault();
                handler(e);
            });
        }
    };
})();
"""
