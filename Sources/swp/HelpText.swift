/// The `?` overlay's contents, grouped by what the keys are for.
///
/// Kept beside nothing in particular on purpose: it is the one place the key
/// map is written in prose, and having it as data means the overlay does not
/// have to know what any key does.
enum HelpText {

    static let groups: [(name: String, items: [String])] = [
        ("Move", [
            "↑/↓ or j/k    Move the cursor",
            "g / G         First / last",
            "PgUp / PgDn   Move by a page",
            "Click         Select a row (never acts)",
        ]),
        ("Find", [
            "/             Filter (fuzzy, over every column)",
            "Backspace     Delete a character / leave the box",
            "Esc           Leave the box, then clear it, then quit",
            "a             Every process / only the ones holding a port",
            "m             Only mine / every user",
            "s             Change the sort order",
            "r             Re-scan now (it also re-scans every 2s)",
        ]),
        ("Act", [
            "Enter or x    Send the default signal (asks first)",
            "X             Send SIGKILL (asks first)",
            "y             Copy the pid",
        ]),
        ("Notes", [
            "j/k move,     x kills — never the other way round, so the",
            "              key next to \"up\" can't end a process",
            "sudo swp      Other users' ports are invisible without it",
            "q / Esc       Quit",
        ]),
    ]
}
