import SwiftUI

/// The closed or open lock that marks a driven session, with its owner and
/// state on hover. Renders nothing for a session that was never driven.
struct DrivenLockIcon: View {
    let driven: DrivenState?
    let size: CGFloat
    let color: Color

    var body: some View {
        if let driven {
            Image(systemName: driven.locked ? "lock.fill" : "lock.open")
                .font(.system(size: size))
                .foregroundColor(color)
                .help(driven.summary(time: Self.time))
        }
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = Calendar.current.isDateInToday(date) ? .none : .short
        return formatter.string(from: date)
    }
}
