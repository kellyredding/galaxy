import SwiftUI
import AppKit

/// A read-only text field with a "Choose..." button that opens NSOpenPanel
/// for directory selection. The field always contains a valid directory path.
/// Used in both the New Session sheet and the Settings window.
struct DirectoryField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(size: 13, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
                )

            Button("Choose...") {
                chooseDirectory()
            }
            .controlSize(.small)
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Select a directory"

        // Set initial directory from current value
        let expanded = Self.expandTilde(text)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
            panel.directoryURL = URL(fileURLWithPath: expanded)
        }

        if panel.runModal() == .OK, let url = panel.url {
            text = Self.abbreviatePath(url.path)
        }
    }

    /// Open an NSOpenPanel for directory selection, returning the abbreviated path or nil if cancelled.
    static func pickDirectory(startingAt currentPath: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Select a directory"

        let expanded = expandTilde(currentPath)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
            panel.directoryURL = URL(fileURLWithPath: expanded)
        }

        if panel.runModal() == .OK, let url = panel.url {
            return abbreviatePath(url.path)
        }
        return nil
    }

    // MARK: - Static Helpers

    /// Expand ~ to the user's home directory for OS-level file operations.
    static func expandTilde(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        return path.replacingOccurrences(
            of: "~",
            with: NSHomeDirectory(),
            range: path.startIndex..<path.index(after: path.startIndex)
        )
    }

    /// Replace home directory prefix with ~ for display.
    static func abbreviatePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
