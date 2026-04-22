import SwiftUI
import AppKit

/// Row model for the long-press dropdown. Identifiable by UUID
/// to match `NavigationEntry.id` semantics — clicking a row
/// fires `onSelect` with that id.
struct LongPressMenuItem: Identifiable {
    let id: UUID
    let title: String
    let systemImage: String?
}

/// SwiftUI wrapper for an NSButton that fires `onClick` on a
/// quick click and presents an NSMenu on long-press. Matches
/// the Safari/Slack chrome back/forward pattern.
///
/// - Click (≤ `longPressDelay`): fires `onClick`
/// - Hold (> `longPressDelay`): builds menu via `menuItems`
///   and presents it below the button. Selection fires
///   `onSelect(id)`.
struct LongPressMenuButton: NSViewRepresentable {
    let systemImage: String
    let help: String
    let isEnabled: Bool
    let menuItems: () -> [LongPressMenuItem]
    let onClick: () -> Void
    let onSelect: (UUID) -> Void

    static let longPressDelay: TimeInterval = 0.25

    func makeNSView(context: Context) -> LongPressButton {
        let button = LongPressButton()
        button.systemImage = systemImage
        button.toolTip = help
        button.isEnabled = isEnabled
        button.delegate = context.coordinator
        return button
    }

    func updateNSView(
        _ button: LongPressButton,
        context: Context
    ) {
        button.isEnabled = isEnabled
        button.toolTip = help
        button.systemImage = systemImage
        button.delegate = context.coordinator
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: LongPressButtonDelegate {
        var parent: LongPressMenuButton

        init(parent: LongPressMenuButton) {
            self.parent = parent
        }

        func longPressButtonClicked(
            _ button: LongPressButton
        ) {
            parent.onClick()
        }

        func longPressButtonShouldShowMenu(
            _ button: LongPressButton
        ) -> NSMenu? {
            let items = parent.menuItems()
            guard !items.isEmpty else { return nil }
            let menu = NSMenu()
            for item in items {
                let menuItem = NSMenuItem(
                    title: item.title,
                    action: #selector(
                        LongPressButton
                            .menuItemSelected(_:)
                    ),
                    keyEquivalent: ""
                )
                menuItem.target = button
                menuItem.representedObject = item.id
                if let sys = item.systemImage {
                    menuItem.image = NSImage(
                        systemSymbolName: sys,
                        accessibilityDescription: nil
                    )
                }
                menu.addItem(menuItem)
            }
            return menu
        }

        func longPressButtonMenuItemSelected(
            _ button: LongPressButton, id: UUID
        ) {
            parent.onSelect(id)
        }
    }
}

protocol LongPressButtonDelegate: AnyObject {
    func longPressButtonClicked(_ button: LongPressButton)
    func longPressButtonShouldShowMenu(
        _ button: LongPressButton
    ) -> NSMenu?
    func longPressButtonMenuItemSelected(
        _ button: LongPressButton, id: UUID
    )
}

/// NSButton that distinguishes click from long-press by
/// polling events against a deadline. A timer-based approach
/// doesn't work here because `Timer.scheduledTimer` fires in
/// `.default` run-loop mode only, but mouse-drag tracking
/// runs in `.eventTracking` mode — the timer never fires
/// during a press.
///
/// Instead we use `nextEvent(matching:until:inMode:dequeue:)`
/// with the long-press deadline: if mouseUp arrives before
/// the deadline, fire click; if `nil` comes back (timeout),
/// present the menu.
final class LongPressButton: NSButton {
    weak var delegate: LongPressButtonDelegate?

    var systemImage: String = "" {
        didSet { updateImage() }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        self.bezelStyle = .regularSquare
        self.isBordered = false
        self.imagePosition = .imageOnly
        self.imageScaling = .scaleProportionallyDown
        self.setButtonType(.momentaryChange)
        // Don't use target/action — we intercept mouseDown
        // entirely.
        self.target = nil
        self.action = nil
    }

    private func updateImage() {
        guard !systemImage.isEmpty else {
            self.image = nil
            return
        }
        self.image = NSImage(
            systemSymbolName: systemImage,
            accessibilityDescription: nil
        )
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        guard let window = self.window else { return }

        self.highlight(true)
        defer { self.highlight(false) }

        let deadline = Date(
            timeIntervalSinceNow:
                LongPressMenuButton.longPressDelay
        )

        // Pull events until mouseUp (= click) or deadline
        // passes with no mouseUp (= long press → menu).
        // Drag events are consumed but ignored so the user
        // can wiggle within the button without cancelling.
        while true {
            let next = window.nextEvent(
                matching: [
                    .leftMouseUp, .leftMouseDragged,
                ],
                until: deadline,
                inMode: .eventTracking,
                dequeue: true
            )

            guard let ev = next else {
                // Timeout — deadline reached, present menu.
                presentLongPressMenu()
                return
            }

            if ev.type == .leftMouseUp {
                delegate?.longPressButtonClicked(self)
                return
            }
            // Drag: continue polling until deadline.
        }
    }

    private func presentLongPressMenu() {
        guard let menu = delegate?
            .longPressButtonShouldShowMenu(self)
        else { return }
        let origin = NSPoint(x: 0, y: self.bounds.height)
        menu.popUp(
            positioning: nil, at: origin, in: self
        )
    }

    @objc func menuItemSelected(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID
        else { return }
        delegate?.longPressButtonMenuItemSelected(
            self, id: id
        )
    }
}
