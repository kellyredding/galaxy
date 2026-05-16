import SwiftUI

struct NewSessionView: View {
    /// Callback to dismiss the window.
    let onDismiss: () -> Void

    // Focus management
    enum FocusField: Hashable {
        case directory, persona, name, vibe, create
    }
    @FocusState private var focusedField: FocusField?

    // Form state
    @State private var startDir: String
    @State private var selectedPersona: String? = nil
    @State private var givenName: String = ""
    @State private var isVibe: Bool = false
    @State private var errorMessage: String? = nil
    @State private var personaBridge = PersonaPickerBridge()

    // Environment
    private let hasClaudePersona: Bool
    private let availablePersonas: [String]

    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        self.hasClaudePersona = SessionManager.shared.claudePersonaPath != nil

        // Glob persona TOML files
        let personaDir = NSHomeDirectory() + "/.claude-persona/personas"
        var personas: [String] = []
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: personaDir) {
            personas = entries
                .filter { $0.hasSuffix(".toml") }
                .map { String($0.dropLast(5)) }  // strip .toml
                .sorted()
        }
        self.availablePersonas = personas

        // Pre-fill start directory from default setting
        _startDir = State(
            initialValue: SettingsManager.shared.settings.newSessionDefaultDir
        )

        // Pre-fill persona from last-used
        _selectedPersona = State(
            initialValue: SettingsManager.shared.settings.newSessionLastPersona
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Session name
            VStack(alignment: .leading, spacing: 6) {
                Text("Name (optional)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)

                TextField("Eventually auto-generated if none given", text: $givenName)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .name)
            }

            // Persona picker (only if claude-persona is installed)
            if hasClaudePersona {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Persona")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)

                    PersonaPicker(
                        personas: availablePersonas,
                        selection: $selectedPersona,
                        bridge: personaBridge
                    )
                    .focusable()
                    .focused($focusedField, equals: .persona)
                    .onKeyPress(.space) {
                        personaBridge.performClick?()
                        return .handled
                    }
                }
            }

            // Start directory
            VStack(alignment: .leading, spacing: 6) {
                Text("Start directory")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)

                HStack(spacing: 8) {
                    Text(startDir)
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
                        openDirectoryPicker()
                    }
                    .controlSize(.small)
                }
                .focusable()
                .focused($focusedField, equals: .directory)
                .onKeyPress(.space) {
                    openDirectoryPicker()
                    return .handled
                }

                // Error message
                if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.system(size: 11))
                }
            }
            .onChange(of: startDir) { _, _ in
                errorMessage = nil
            }

            // Vibe mode checkbox
            Toggle("Vibe (dangerously skip permissions)", isOn: $isVibe)
                .toggleStyle(.checkbox)
                .focusable()
                .focused($focusedField, equals: .vibe)
                .onKeyPress(.space) {
                    isVibe.toggle()
                    return .handled
                }

            // Buttons
            HStack {
                Spacer()
                Button("Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(startDir.trimmingCharacters(in: .whitespaces).isEmpty)
                    .focusable()
                    .focused($focusedField, equals: .create)
                    .onKeyPress(.space) {
                        submit()
                        return .handled
                    }
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            DispatchQueue.main.async {
                focusedField = .name
            }
        }
    }

    // MARK: - Actions

    private func openDirectoryPicker() {
        if let dir = DirectoryField.pickDirectory(startingAt: startDir) {
            startDir = dir
        }
    }

    // MARK: - Submission

    private func submit() {
        var trimmed = startDir.trimmingCharacters(in: .whitespaces)

        // Strip trailing slash for consistency — paths from the CLI URL
        // handler never have trailing slashes.
        if trimmed.hasSuffix("/") && trimmed.count > 1 {
            trimmed = String(trimmed.dropLast())
        }

        // Validate non-empty
        guard !trimmed.isEmpty else {
            errorMessage = "Start directory is required."
            return
        }

        // Expand tilde for existence check and createSession
        let expanded = DirectoryField.expandTilde(trimmed)

        // Validate directory exists
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir),
              isDir.boolValue else {
            errorMessage = "Directory does not exist: \(trimmed)"
            return
        }

        // Record last-used persona in settings
        SettingsManager.shared.settings.newSessionLastPersona = selectedPersona

        // Create session with expanded path — Session.workingDirectory must
        // be a fully expanded absolute path (same contract as URL handler).
        // Normalize given name: empty string → nil (let auto-generation handle it)
        let trimmedName = givenName.trimmingCharacters(in: .whitespaces)
        let finalName: String? = trimmedName.isEmpty ? nil : trimmedName

        SessionManager.shared.createSession(
            workingDirectory: expanded,
            personaName: selectedPersona,
            givenName: finalName,
            isVibe: isVibe
        )

        onDismiss()
    }
}
