#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension Terminal {

    enum Key: Equatable {
        case up, down, left, right
        case pageUp, pageDown, home, end
        case enter, escape, backspace, tab
        case char(Character)
        case ctrlC          // only reachable if a terminal delivers it as a byte
        case ctrlL          // force redraw
        case mouseScroll(Int)               // positive = down
        case mouseClick(x: Int, y: Int)     // 1-based column and row
        case other
    }

    /// A key read ahead of its turn and handed back. Scroll coalescing drains
    /// the queued wheel events and must return the one non-scroll key that
    /// ended the drain.
    private static var pushedBack: Key?

    static func pushBack(_ key: Key) { pushedBack = key }

    static func readKey() -> Key { readKey(timeoutMs: nil)! }

    /// Read one logical key, or nil if `timeoutMs` elapses first.
    static func readKey(timeoutMs: Int32?) -> Key? {
        if let queued = pushedBack { pushedBack = nil; return queued }
        // nil here is EOF (Ctrl-D, or a closed stdin). Treated as Escape so the
        // caller unwinds instead of spinning on a stream that will never speak.
        guard let first = readByte(timeoutMs: timeoutMs) else {
            return timeoutMs != nil ? nil : .escape
        }
        return decodeKey(first: first, next: { readByte(timeoutMs: $0) })
    }

    /// Collapse a run of queued scroll events into one delta.
    ///
    /// A trackpad flick emits an event per notch and each would repaint the
    /// whole list. Only where the scroll ends matters, so the pending deltas are
    /// summed and the frame drawn once.
    static func coalesceScroll(_ delta: Int) -> Int {
        var total = delta
        while let next = readKey(timeoutMs: 0) {
            guard case .mouseScroll(let d) = next else { pushBack(next); break }
            total += d
        }
        return total
    }

    /// Pure decoder: the first byte plus a closure yielding the rest (taking the
    /// same poll timeout, nil on timeout or EOF). Free of stdin so the escape
    /// parsing can be tested by feeding it byte arrays.
    static func decodeKey(first: UInt8, next: (Int32) -> UInt8?) -> Key {
        guard first == 0x1B else { return decodePlain(first) }

        // A lone ESC and the start of a sequence look identical until the next
        // byte does or does not arrive; 40 ms is long enough for a terminal that
        // is sending one and short enough that pressing Escape feels immediate.
        guard let intro = next(40) else { return .escape }
        guard intro == 0x5B /* [ */ || intro == 0x4F /* O */ else { return .escape }
        guard let b2 = next(40) else { return .escape }

        switch b2 {
        case 0x3C /* < */: return decodeMouse(next: next)
        case 0x41: return .up
        case 0x42: return .down
        case 0x43: return .right
        case 0x44: return .left
        case 0x48: return .home
        case 0x46: return .end
        case 0x30...0x39:
            // A parameter list, consumed whole up to its final byte — otherwise
            // the tail of a modified-key sequence leaks out as stray keystrokes,
            // and in this program a stray keystroke can be an action.
            var params: [Int] = []
            var current = Int(b2 - 0x30)
            var finalByte: UInt8 = 0x7E
            while let d = next(40) {
                if d >= 0x30, d <= 0x39 { current = current * 10 + Int(d - 0x30) }
                else if d == 0x3B /* ; */ { params.append(current); current = 0 }
                else { params.append(current); finalByte = d; break }
            }
            guard finalByte == 0x7E else {
                // Modified arrows: ESC [ 1 ; <mod> A/B/C/D. The modifier is
                // dropped — nothing here binds one — but the arrow still moves.
                switch finalByte {
                case 0x41: return .up
                case 0x42: return .down
                case 0x43: return .right
                case 0x44: return .left
                default: return .other
                }
            }
            switch params.first ?? 0 {
            case 1, 7: return .home
            case 4, 8: return .end
            case 5: return .pageUp
            case 6: return .pageDown
            default: return .other
            }
        default:
            return .other
        }
    }

    /// SGR mouse report: `ESC [ < button ; col ; row M|m`.
    private static func decodeMouse(next: (Int32) -> UInt8?) -> Key {
        var button = 0, x = 0, y = 0
        var current = 0
        var field = 1   // 1 = button, 2 = column, 3 = row
        while let b = next(40) {
            if b == 0x3B /* ; */ {
                field += 1
                current = 0
            } else if b == 0x4D /* M */ || b == 0x6D /* m */ {
                // The button field packs modifiers alongside the number: bit 5
                // (32) is motion and bit 6 (64) the wheel, so they are masked
                // off before the button is read.
                let isPress = b == 0x4D
                let wheel = (button & 64) != 0
                let btn = button & 3
                if wheel {
                    // 64/65 are wheel up/down; 66/67 are the horizontal tilt,
                    // which masks to the same 2/3 and would otherwise read as a
                    // vertical scroll. There is nothing to scroll sideways.
                    guard isPress, btn < 2 else { return .other }
                    return .mouseScroll(btn == 0 ? -3 : 3)
                }
                // Presses only, left button only: a release would fire a second
                // action for one click, and in this list an action is a signal.
                guard isPress, btn == 0, (button & 32) == 0 else { return .other }
                return .mouseClick(x: x, y: y)
            } else if b >= 0x30, b <= 0x39 {
                current = current * 10 + Int(b - 0x30)
                switch field {
                case 1: button = current
                case 2: x = current
                default: y = current
                }
            } else {
                break
            }
        }
        return .other
    }

    private static func decodePlain(_ byte: UInt8) -> Key {
        switch byte {
        case 0x0D, 0x0A: return .enter
        case 0x09: return .tab
        // Ctrl-C arrives as SIGINT (ISIG stays on in raw mode), so this byte is
        // normally never seen. It must not decode as "c" regardless: a typed "c"
        // would be indistinguishable from it.
        case 0x03: return .ctrlC
        case 0x0C: return .ctrlL
        case 0x7F, 0x08: return .backspace
        default:
            if byte >= 0x20, byte < 0x7F { return .char(Character(UnicodeScalar(byte))) }
            return .other
        }
    }

    /// One raw byte from stdin, or nil if `timeoutMs` passes without one.
    private static func readByte(timeoutMs: Int32? = nil) -> UInt8? {
        if let timeout = timeoutMs {
            var fds = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            if poll(&fds, 1, timeout) <= 0 { return nil }
        }
        var byte: UInt8 = 0
        return read(STDIN_FILENO, &byte, 1) == 1 ? byte : nil
    }
}
