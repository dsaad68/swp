import Foundation

/// Small formatting helpers shared by the picker and the printed listing, so a
/// row looks the same whichever one drew it.
public enum Format {

    /// Bytes as a short, fixed-ish width string: `12M`, `1.4G`, `812K`.
    ///
    /// One decimal only below 10 in a unit, which keeps the column at four
    /// characters for everything a process realistically uses while still
    /// telling `1.4G` from `9.9G`. Powers of 1024, because that is what every
    /// other process viewer on the machine means by `M`.
    public static func bytes(_ value: UInt64?) -> String {
        guard let value else { return "-" }
        let units = ["B", "K", "M", "G", "T"]
        var size = Double(value)
        var unit = 0
        while size >= 1024, unit < units.count - 1 {
            size /= 1024
            unit += 1
        }
        if unit == 0 { return "\(Int(size))B" }
        return size < 10
            ? String(format: "%.1f%@", size, units[unit])
            : String(format: "%.0f%@", size, units[unit])
    }

    /// A CPU share as a percentage of one core: `4.2%`, `137%`, `-` when the
    /// kernel would not say.
    ///
    /// A decimal only below 10, so the column stays four or five characters
    /// wide for everything real while still telling 0.4% from 4%. Above 100 the
    /// decimal is noise — a process using more than one core is the answer
    /// whether it is at 137% or 141%.
    public static func percent(_ value: Double?) -> String {
        guard let value else { return "-" }
        if value < 0.05 { return "0%" }
        return value < 10 ? String(format: "%.1f%%", value) : String(format: "%.0f%%", value)
    }

    /// How long ago `date` was, coarsely: `3s`, `12m`, `4h`, `9d`.
    ///
    /// Uptime is read to answer "is this the server I just started, or the one
    /// from Tuesday I forgot about" — a single unit answers that, and a
    /// two-unit `4h 12m` would cost a column it never earns back.
    public static func elapsed(since date: Date?, now: Date = Date()) -> String {
        guard let date else { return "-" }
        let seconds = Int(now.timeIntervalSince(date))
        // A clock that stepped backwards (or a start time read a hair into the
        // future) must not print "-3s"; the process is new either way.
        if seconds < 1 { return "0s" }
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }

    /// Cut `text` to `width` display columns, marking the cut with `…`.
    ///
    /// Truncation keeps the head: a command line's distinguishing part is its
    /// start (`node server.js …`), unlike a file path. Widths below 2 fall back
    /// to a plain prefix, since an ellipsis alone would say nothing.
    public static func truncate(_ text: String, to width: Int) -> String {
        guard width > 0 else { return "" }
        guard Ansi.displayWidth(text) > width else { return text }
        guard width > 1 else { return String(text.prefix(width)) }
        var out = ""
        var used = 0
        for ch in text {
            let w = Ansi.displayWidth(String(ch))
            if used + w > width - 1 { break }
            out.append(ch)
            used += w
        }
        return out + "…"
    }

    /// Pad `text` to `width` display columns (left-aligned). Text already at or
    /// over the width is returned untouched — padding never truncates, so a
    /// caller that wants both asks for both and the order stays theirs.
    public static func pad(_ text: String, to width: Int) -> String {
        let w = Ansi.displayWidth(text)
        return w >= width ? text : text + String(repeating: " ", count: width - w)
    }

    /// Pad `text` to `width` display columns, right-aligned — for the numeric
    /// columns (pid, memory), where the digits should line up.
    public static func padLeft(_ text: String, to width: Int) -> String {
        let w = Ansi.displayWidth(text)
        return w >= width ? text : String(repeating: " ", count: width - w) + text
    }
}
