import Foundation

/// Writes Galaxy's text-entry keystrokes into Claude Code's own keybindings
/// file, so the session pane answers to the same keys as the composers.
///
/// Galaxy is not authoritative over the whole file. It owns a set of keys
/// inside the `Chat` context and leaves everything else — other contexts, other
/// keys in `Chat`, `$schema`, `$docs`, unknown fields — exactly as it found
/// them. The file is global and assist-ant reads it too, so anything not
/// explicitly ours is somebody else's.
///
/// The read-merge-backup-write shape mirrors what Claude Code's own
/// `/terminal-setup` does to VS Code's keybindings, which is the closest thing
/// to a sanctioned precedent for editing this file from outside.
enum ClaudeKeybindingsWriter {
    static let fileURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".claude/keybindings.json")

    static let backupURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".claude/keybindings.json.bak")

    /// The context the user's own keystrokes are written into. Everything else
    /// in the file is left alone — bindings are per-context, and Claude Code
    /// dispatches pickers, permission prompts and dialogs through contexts of
    /// their own.
    static let context = "Chat"

    /// Each reserved chord, the context it lives in, and what it does there.
    ///
    /// `Chat` only, and deliberately so. Claude Code's completion popup is
    /// cleared with a plain Tab before submitting rather than with a bound
    /// chord — see `SessionSubmit`. Binding anything in `Autocomplete` was
    /// tried and is worse: a bound action *consumes* the key, so the popup
    /// closed and nothing else happened, while an unbound one is swallowed by
    /// the popup entirely. Only Return has accept-then-propagate semantics
    /// there, and binding a key is precisely what suppresses them.
    static var reservedContexts: [(context: String, binding: Keystroke, action: String)] {
        [("Chat", Keystroke.reservedMachineSubmit, Action.submit.rawValue)]
    }

    enum Action: String {
        case submit = "chat:submit"
        case newline = "chat:newline"
    }

    struct SyncResult {
        /// Binding strings Galaxy wrote, in file order.
        let written: [String: String]
        /// Keystrokes that reach the composers but have no documented Claude
        /// Code spelling, so the session pane cannot honour them.
        let unsupported: [Keystroke]
        /// True when the file already said exactly this.
        let alreadyInSync: Bool
    }

    // MARK: - Building

    /// The bindings Galaxy owns, derived from the settings.
    ///
    /// The reserved machine-submit chord is always present and always maps to
    /// submit. It is not a user preference — every automated prompt Galaxy
    /// sends depends on it, so it has to survive whatever the user chooses.
    static func ownedBindings(
        for bindings: TextEntryBindings
    ) -> (map: [String: String], unsupported: [Keystroke]) {
        var map: [String: String] = [:]
        var unsupported: [Keystroke] = []

        // Newline first, then submit, so a keystroke in both lists ends up
        // submitting — the same tie-break the in-app matcher makes.
        for keystroke in bindings.newline {
            guard let binding = keystroke.claudeBinding else {
                unsupported.append(keystroke)
                continue
            }
            map[binding] = Action.newline.rawValue
        }
        for keystroke in bindings.submit {
            guard let binding = keystroke.claudeBinding else {
                unsupported.append(keystroke)
                continue
            }
            map[binding] = Action.submit.rawValue
        }

        if let reserved = Keystroke.reservedMachineSubmit.claudeBinding {
            map[reserved] = Action.submit.rawValue
        }
        return (map, unsupported)
    }

    // MARK: - Writing

    /// Merge Galaxy's bindings into the file, backing up first.
    ///
    /// Returns without writing when the file already matches, so opening
    /// settings does not churn a backup on every visit.
    @discardableResult
    static func sync(_ bindings: TextEntryBindings) throws -> SyncResult {
        let (owned, unsupported) = ownedBindings(for: bindings)
        var root = try readRoot()
        var changed = false

        // The user's keystrokes go into Chat only. They must never reach
        // Autocomplete, where Return means "accept this completion".
        changed = upsert(owned, into: context, of: &root) || changed

        // The reserved chord additionally goes wherever an automated prompt
        // might land — see `reservedContexts`.
        for entry in reservedContexts where entry.context != context {
            guard let binding = entry.binding.claudeBinding else { continue }
            changed =
                upsert([binding: entry.action],
                       into: entry.context, of: &root) || changed
        }

        guard changed || !FileManager.default.fileExists(atPath: fileURL.path)
        else {
            return SyncResult(
                written: owned, unsupported: unsupported, alreadyInSync: true)
        }

        try backupExisting()
        try writeAtomically(root)
        return SyncResult(
            written: owned, unsupported: unsupported, alreadyInSync: false)
    }

    /// Make sure the file carries the reserved machine-submit binding in every
    /// context an automated prompt can land in, adding it where absent and
    /// leaving everything else alone.
    ///
    /// Called at launch, and deliberately narrower than `sync`: it writes *only*
    /// the reserved chord, never the user's chosen keystrokes. The file is
    /// global, so pushing this app's full binding set on every launch would
    /// stomp whatever assist-ant last wrote, for no reason.
    ///
    /// This is what lets automated submission stop reasoning about whether a
    /// sync has happened. The chord is present because Galaxy put it there, not
    /// because the user visited a settings pane.
    @discardableResult
    static func ensureReservedBinding() throws -> Bool {
        guard !hasReservedBinding else { return false }

        var root = try readRoot()
        var changed = false
        for entry in reservedContexts {
            guard let binding = entry.binding.claudeBinding else { continue }
            changed =
                upsert([binding: entry.action],
                       into: entry.context, of: &root) || changed
        }
        guard changed else { return false }

        try backupExisting()
        try writeAtomically(root)
        return true
    }

    /// Merge keys into one context block, creating the block if it is absent.
    /// Returns whether anything actually changed, so callers can skip writing.
    private static func upsert(
        _ keys: [String: String],
        into name: String,
        of root: inout [String: Any]
    ) -> Bool {
        var blocks = root["bindings"] as? [[String: Any]] ?? []
        var index = blocks.firstIndex { $0["context"] as? String == name }
        if index == nil {
            blocks.append(["context": name, "bindings": [String: Any]()])
            index = blocks.count - 1
        }
        guard let index else { return false }

        var block = blocks[index]
        var existing = block["bindings"] as? [String: Any] ?? [:]
        let before = existing
        // Only the keys we own are touched; everything else in this context is
        // left exactly as found.
        for (key, action) in keys { existing[key] = action }

        if NSDictionary(dictionary: before).isEqual(to: existing) {
            return false
        }
        block["bindings"] = existing
        blocks[index] = block
        root["bindings"] = blocks
        root["$schema"] =
            root["$schema"]
            ?? "https://www.schemastore.org/claude-code-keybindings.json"
        return true
    }

    /// Whether an automated prompt can rely on the reserved chord, repairing
    /// the file if it exists but has lost it.
    ///
    /// Evaluated per submission rather than cached, so a file edited or deleted
    /// after launch is noticed immediately.
    ///
    /// Repair rather than fall back, because falling back is not actually safe
    /// here: if the chord was removed while `enter` is still bound to
    /// `chat:newline`, a carriage return inserts a newline and the prompt never
    /// sends. The chord is Galaxy's own infrastructure — 3e keeps it out of the
    /// settings UI for exactly this reason — so restoring it is repairing
    /// damage, not overriding a preference.
    ///
    /// A missing file is different and genuinely does fall back: with no
    /// bindings at all Claude Code is on its `enter: chat:submit` default, so a
    /// carriage return is the only thing that works.
    static var reservedBindingIsUsable: Bool {
        if hasReservedBinding { return true }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return false
        }
        do {
            try ensureReservedBinding()
        } catch {
            GalaxyLog.dbg(
                "keybindings",
                "the reserved binding is missing and could not be restored "
                    + "(\(error)) — falling back to a carriage return"
            )
            return false
        }
        GalaxyLog.dbg(
            "keybindings", "restored the reserved machine-submit binding")
        return hasReservedBinding
    }

    /// Whether the file currently carries Galaxy's reserved machine-submit
    /// binding.
    ///
    /// This is what tells automated submission which bytes to send. It reads
    /// the file rather than trusting a flag because the file is global,
    /// hot-reloaded, and editable by hand or by assist-ant — a cached "we
    /// synced once" belief could be false by the time it mattered, and the
    /// failure would be a prompt silently not sending.
    ///
    /// Reads are cheap (a few hundred bytes) and happen once per automated
    /// submission, not per keystroke.
    /// True only when the chord is bound in *every* context an automated
    /// prompt can land in. Present in some but not others is the state that
    /// makes automation work for plain text and fail for slash commands, so it
    /// counts as absent and gets repaired.
    static var hasReservedBinding: Bool {
        let root = (try? readRoot()) ?? [:]
        let blocks = root["bindings"] as? [[String: Any]] ?? []

        return reservedContexts.allSatisfy { entry in
            guard let binding = entry.binding.claudeBinding else { return true }
            return blocks.contains { block in
                block["context"] as? String == entry.context
                    && (block["bindings"] as? [String: Any])?[binding]
                        as? String == entry.action
            }
        }
    }

    // MARK: - File handling

    private static func readRoot() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        // A file that exists but does not parse is left for the backup to
        // preserve rather than merged into — merging into a guess would be a
        // silent way to lose whatever was actually in there.
        guard let root = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any]
        else { return [:] }
        return root
    }

    private static func backupExisting() throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: fileURL.path) else { return }
        if manager.fileExists(atPath: backupURL.path) {
            try manager.removeItem(at: backupURL)
        }
        try manager.copyItem(at: fileURL, to: backupURL)
    }

    private static func writeAtomically(_ root: [String: Any]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        // .atomic so a crash mid-write cannot leave Claude Code reading a
        // half-file. It hot-reloads this path, so a torn write would be
        // observed, not merely persisted.
        try data.write(to: fileURL, options: .atomic)
    }
}
