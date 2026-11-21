import AppKit
import Galactic
import SwiftUI

/// The Ledger tab's account of a driven session: who owns it, whether it is
/// locked, the owner's token, and the person's backstop for taking it back.
///
/// The token is here so an owner that lost it can be given it again; without
/// it nothing can ever lock the session once more.
struct LedgerDrivenSessionRows: View {
    @ObservedObject var session: Session
    let fontSize: ChromeFontSize

    @State private var revealsToken = false

    var body: some View {
        if let driven = session.driven {
            row("Owner") {
                Text(driven.owner)
                    .chromeFontMono(size: fontSize.caption2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
            }
            row("Lock") {
                HStack(spacing: 5) {
                    DrivenLockIcon(
                        driven: driven, size: fontSize.caption2, color: .primary)
                    Text(lockText(driven))
                        .chromeFontMono(size: fontSize.caption2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            row("Token") {
                HStack(spacing: 6) {
                    Text(revealsToken ? driven.token : String(repeating: "•", count: 16))
                        .chromeFontMono(size: fontSize.caption2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button(action: { revealsToken.toggle() }) {
                        Image(systemName: revealsToken ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.plain)
                    .help(revealsToken ? "Hide the token" : "Show the token")
                    Button(action: { copy(driven.token) }) {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .help("Copy the token")
                }
                .font(.system(size: fontSize.caption2))
                .foregroundColor(.secondary)
            }
            if driven.locked {
                row("") {
                    Button("Force release…") { confirmForceRelease(owner: driven.owner) }
                        .controlSize(.small)
                        .help("Take the lock away from \(driven.owner)")
                }
            }
        }
    }

    private func lockText(_ driven: DrivenState) -> String {
        if driven.locked {
            return driven.lastLockedAt.map { "Locked since \(DrivenLockIcon.time($0))" }
                ?? "Locked"
        }
        let by = driven.lastReleasedBy == .user ? " by you" : ""
        return driven.lastReleasedAt.map { "Released\(by) at \(DrivenLockIcon.time($0))" }
            ?? "Released\(by)"
    }

    private func row<Value: View>(
        _ label: String, @ViewBuilder value: () -> Value
    ) -> some View {
        HStack(alignment: .center) {
            Text(label)
                .chromeFont(size: fontSize.caption2)
                .foregroundColor(.secondary)
                .frame(width: 90, alignment: .trailing)
            value()
        }
    }

    private func copy(_ token: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(token, forType: .string)
    }

    private func confirmForceRelease(owner: String) {
        guard let window = SheetAlert.hostWindow() else { return }
        let sessionID = session.id
        SheetAlert.confirm(
            in: window,
            message: "Force release this session?",
            detail: "\(owner) is driving it and will be told the lock was "
                + "taken from it. Ask \(owner) to release it instead unless it "
                + "can't respond.",
            confirm: "Force Release",
            onConfirm: {
                _ = DrivenSessionService.shared.forceRelease(sessionID: sessionID)
            }
        )
    }
}
