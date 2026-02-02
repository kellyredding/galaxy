import SwiftUI

@main
struct GalaxyPOCApp: App {
    @StateObject private var sessionManager = SessionManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sessionManager)
        }
        .windowStyle(.automatic)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session") {
                    sessionManager.createSession()
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            CommandMenu("Sessions") {
                ForEach(Array(sessionManager.sessions.enumerated()), id: \.element.id) { index, session in
                    if index < 9 {
                        Button(session.name) {
                            sessionManager.switchTo(sessionId: session.id)
                        }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    }
                }
            }
        }
    }
}
