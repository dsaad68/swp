import Foundation
import swpCore

extension ProcessMenu {

    /// What a keystroke does.
    ///
    /// Split from the loop and the data because it is the part that has to be
    /// read as a whole to be trusted: it is where a key becomes an action, and
    /// one of those actions sends a signal. Everything here is either a cursor
    /// move or a call into `ProcessMenu.swift` — no state is derived in this
    /// file, so what a key does is exactly what its case says.

    enum Step { case stay, quit }

    mutating func handle(_ key: Terminal.Key, viewport: Int) -> Step {
        switch key {
        // ── Always active: navigation cannot collide with typing. ──
        case .up:
            move(by: -1)
        case .down:
            move(by: 1)
        case .pageUp:
            move(by: -viewport)
        case .pageDown:
            move(by: viewport)
        case .home:
            selected = 0
        case .end:
            selected = max(0, rows.count - 1)
        case .mouseScroll(let delta):
            move(by: Terminal.coalesceScroll(delta))
        case .mouseClick(_, let y):
            // Selects only, never acts. A double-click that killed something
            // would be a mis-click away from a lost process, and the mouse is
            // the one input with no confirmation habit attached to it.
            let offset = y - 1 - chrome(for: Terminal.size()).headerLines
            if offset >= 0, offset < viewport, top + offset < rows.count { selected = top + offset }
        case .enter:
            act(with: signal)
        case .ctrlL:
            Terminal.clearScreen()
        case .ctrlC:
            return .quit

        // ── Filter box ──
        case .char("/") where !searching:
            searching = true
        case .escape:
            if searching {
                searching = false
            } else if !filter.isEmpty {
                filter = ""
                applyFilter()
            } else {
                return .quit
            }
        case .backspace:
            if searching, !filter.isEmpty {
                filter.removeLast()
                applyFilter()
            } else {
                searching = false
            }

        // ── List-mode keys, ignored while typing so the letters stay letters ──
        case .char("j") where !searching:
            move(by: 1)
        case .char("k") where !searching:
            move(by: -1)
        case .char("g") where !searching:
            selected = 0
        case .char("G") where !searching:
            selected = max(0, rows.count - 1)
        case .char("q") where !searching, .char("Q") where !searching:
            return .quit
        case .char("a") where !searching:
            includePortless.toggle()
            refresh()
        case .char("s") where !searching:
            sort = sort.next
            rebuildCandidates()
            applyFilter()
        case .char("r") where !searching:
            refresh()
            note("refreshed")
        case .char("y") where !searching:
            copyPid()
        case .char("?") where !searching:
            Terminal.showHelp(HelpText.groups, theme: theme)
        case .char("m") where !searching:
            user = user == nil ? getuid() : nil
            refresh()

        // ── Acting. `x`/`X` rather than `k`/`K`: `k` is "up" in every list with
        //    vim keys in it, and a tool that kills on the up-arrow's twin is a
        //    tool that will one day kill the wrong thing. ──
        case .char("x") where !searching:
            act(with: signal)
        case .char("X") where !searching:
            act(with: .kill)

        // ── Typing into the box ──
        case .char(let c) where searching:
            filter.append(c)
            applyFilter()

        default:
            break
        }
        return .stay
    }
}
