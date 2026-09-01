import Foundation

public extension Ansi {

    /// Display width of `s` in terminal cells, ignoring any escape sequences it
    /// carries.
    ///
    /// Column layout is computed on styled strings — a row is built with its
    /// colours already in it — so a measurement that counted the escape bytes
    /// would pad every coloured cell by a dozen columns and shear the table.
    /// Combining marks count zero, East Asian wide characters and emoji count
    /// two, everything else one.
    static func displayWidth(_ s: String) -> Int {
        var width = 0
        var iterator = s.unicodeScalars.makeIterator()
        // A zero-width joiner does not just measure zero — it makes the scalar
        // *after* it measure zero too, because the pair is drawn as one glyph.
        // Without this, 👩‍💻 measures 4 and every row carrying one is sheared by
        // two columns.
        var joined = false
        while let scalar = iterator.next() {
            if scalar == "\u{1B}" {
                // Skip the sequence: CSI/OSC run to a final byte, and anything
                // else is a two-character escape. An unterminated sequence
                // consumes the rest of the string, which is the right answer —
                // the terminal will do the same.
                guard let intro = iterator.next() else { break }
                if intro == "[" {
                    while let b = iterator.next(), !(b.value >= 0x40 && b.value <= 0x7E) {}
                } else if intro == "]" {
                    // OSC: ends at BEL or ST (ESC \). Stop on either.
                    while let b = iterator.next() {
                        if b.value == 0x07 { break }
                        if b == "\u{1B}" { _ = iterator.next(); break }
                    }
                }
                continue
            }
            if scalar.value == 0x200D {
                joined = true
                continue
            }
            if joined {
                joined = false
                continue
            }
            width += scalarWidth(scalar)
        }
        return width
    }

    /// Width of a single scalar, with joiners already handled by the caller.
    /// Variation selectors and combining marks count nothing.
    private static func scalarWidth(_ scalar: Unicode.Scalar) -> Int {
        let v = scalar.value
        if (0xFE00...0xFE0F).contains(v) { return 0 }   // variation selectors
        if (0x0300...0x036F).contains(v) { return 0 }   // combining diacriticals
        if v < 0x1100 { return 1 }                       // the fast path: ASCII & Latin
        return isWide(v) ? 2 : 1
    }

    private static func isWide(_ v: UInt32) -> Bool {
        switch v {
        case 0x1100...0x115F,      // Hangul Jamo
             0x2E80...0x303E,      // CJK radicals, Kangxi, CJK symbols
             0x3041...0x33FF,      // Hiragana … CJK compatibility
             0x3400...0x4DBF,      // CJK extension A
             0x4E00...0x9FFF,      // CJK unified ideographs
             0xA000...0xA4CF,      // Yi
             0xAC00...0xD7A3,      // Hangul syllables
             0xF900...0xFAFF,      // CJK compatibility ideographs
             0xFE30...0xFE6F,      // CJK compatibility forms
             0xFF00...0xFF60,      // Fullwidth forms
             0xFFE0...0xFFE6,
             0x1F300...0x1F64F,    // emoji: symbols & pictographs, emoticons
             0x1F680...0x1F6FF,    // transport
             0x1F900...0x1F9FF,    // supplemental symbols
             0x20000...0x3FFFD:    // CJK extensions B+
            return true
        default:
            return false
        }
    }
}
