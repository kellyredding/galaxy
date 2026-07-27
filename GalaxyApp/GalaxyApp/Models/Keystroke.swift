import Foundation

/// A recorded keystroke — a virtual key code plus the modifiers held with it.
///
/// Deliberately Foundation-only, with no AppKit import. Two things rest on
/// that: the smoke target links this file directly without pulling in AppKit,
/// and the matcher stays exercisable in a plain executable. The `NSEvent`
/// bridge lives in its own file for the same reason.
struct Keystroke: Codable, Hashable {
    /// Virtual key codes this feature needs to name, so call sites and
    /// fixtures do not repeat bare numbers. Return and keypad Enter are
    /// genuinely different keys and must not be conflated — a binding on one
    /// is not a binding on the other.
    enum Key {
        static let ret: UInt16 = 36
        static let keypadEnter: UInt16 = 76
    }

    let keyCode: UInt16
    let modifiers: Modifiers

    init(keyCode: UInt16, modifiers: Modifiers = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// The four modifiers a binding may name.
    ///
    /// Encodes as a bare integer rather than a nested object, so the settings
    /// file and the JavaScript twin share one wire format. A fixture table can
    /// then be read by both sides without translation, which is what keeps the
    /// two matchers from drifting apart unnoticed.
    struct Modifiers: OptionSet, Codable, Hashable {
        let rawValue: Int

        init(rawValue: Int) {
            self.rawValue = rawValue
        }

        static let command = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let control = Modifiers(rawValue: 1 << 2)
        static let shift = Modifiers(rawValue: 1 << 3)

        /// Bit positions of the four modifiers within an `NSEvent`
        /// modifier-flags raw value.
        ///
        /// Copied here rather than read from AppKit so that
        /// `init(deviceFlags:)` — and therefore the normalisation it performs —
        /// stays linkable and testable without AppKit. The bridge asserts these
        /// still agree with the framework, so drift cannot pass silently.
        enum DeviceFlag {
            static let capsLock = 1 << 16
            static let shift = 1 << 17
            static let control = 1 << 18
            static let option = 1 << 19
            static let command = 1 << 20
            static let numericPad = 1 << 21
            static let help = 1 << 22
            static let function = 1 << 23
        }

        /// Keep only the four modifiers a binding can name, discarding
        /// caps-lock, fn, the numeric-pad flag, and the device-dependent
        /// left/right bits.
        ///
        /// Without this a match would depend on incidental modifier state:
        /// someone typing with caps-lock on, or pressing the keypad's Enter,
        /// would silently stop matching their own submit binding.
        init(deviceFlags raw: Int) {
            var result: Modifiers = []
            if raw & DeviceFlag.command != 0 { result.insert(.command) }
            if raw & DeviceFlag.option != 0 { result.insert(.option) }
            if raw & DeviceFlag.control != 0 { result.insert(.control) }
            if raw & DeviceFlag.shift != 0 { result.insert(.shift) }
            self = result
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            rawValue = try container.decode(Int.self)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }
}

extension Keystroke {
    /// The DOM `KeyboardEvent.code` this keystroke's key produces inside a
    /// WebView, or nil for a key the JavaScript twin cannot address.
    ///
    /// A WebView never sees a macOS virtual key code, so the JavaScript
    /// matcher compares `code` strings instead. Keeping the mapping on this
    /// side means the JavaScript module carries no table of its own, and the
    /// shared fixture table pins the pairing so the two cannot disagree.
    ///
    /// A nil result means the keystroke cannot be honoured inside a WebView
    /// composer. Whatever vocabulary the recorder ends up permitting has to
    /// account for that rather than assume every recordable key round-trips.
    var domCode: String? {
        switch keyCode {
        case Key.ret: return "Enter"
        case Key.keypadEnter: return "NumpadEnter"
        default: return nil
        }
    }
}
