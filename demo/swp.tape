# swp demo — render with:  just demo
#
# The tape ends by killing a process, so demo/setup.sh stands up three
# disposable listeners first and the kill is SCOPED so it can only ever reach
# one of those.
#
# That scoping is not decoration. An earlier version of this tape filtered the
# picker to "vite" and pressed x on whatever the cursor happened to be on —
# which, because the fuzzy filter also matched identityservicesd and
# DropboxFileProvider, was DropboxFileProvider. The confirmation dialog did its
# job and named the target clearly; the tape pressed y anyway, because a tape
# cannot read. So the kill now runs from `swp -i 5173`, a port query, which is
# exact rather than fuzzy and opens the picker on exactly one row.
#
# Geometry: swp draws exactly as many lines as the terminal has rows, so the
# height has to leave room for all of them or the bottom border is clipped —
# which is what 580 did. 660 with the window bar fits the frame with slack.
# The row count matters for another reason too: swp drops its wordmark header
# below 22 rows, and the demo is partly about what the picker looks like.

Output demo/demo.gif

Require swp

Set FontSize 16
Set Width 1100
Set Height 660
Set Padding 20
Set Theme "Catppuccin Mocha"
Set TypingSpeed 55ms
Set Framerate 24
Set WindowBar Colorful
Set BorderRadius 8

Hide
# swp reads COLORTERM to decide between 24-bit colour and the 256 palette; ttyd
# does not set it, and the difference shows in the wordmark's gradient.
Type "export COLORTERM=truecolor" Enter
Type "clear" Enter
Show

# ── 1. The question it exists to answer ──────────────────────────────────
Type "swp -p 5173"
Sleep 400ms
Enter
Sleep 2.5s

# ── 2. A query answers and exits, so it composes ─────────────────────────
Type "swp --cpu --top 5"
Sleep 400ms
Enter
Sleep 3.5s

Type "clear"
Enter
Sleep 400ms

# ── 3. A bare swp browses ────────────────────────────────────────────────
Type "swp"
Sleep 400ms
Enter
# Long enough for the second scan at 0.25s, which is when CPU figures arrive:
# a rate needs two readings and the first frame has only one.
Sleep 2.5s

Down
Sleep 500ms
Down
Sleep 800ms

# ── 4. The filter is fuzzy, and across every column at once ──────────────
# "vite" finds the server, and also identityservicesd and DropboxFileProvider,
# with the matched letters picked out. That is the feature, and it is exactly
# why the kill below does not happen from here.
Type "/"
Sleep 600ms
Type@130ms "vite"
Sleep 2.2s

Escape
Sleep 400ms
Type "q"
Sleep 800ms

# ── 5. Killing: scoped by an exact port query, and it always asks ────────
Type "swp -i 5173"
Sleep 400ms
Enter
Sleep 2.2s

# g selects the first row. With one row it changes nothing; it is here so the
# next key cannot land on a neighbour if this list is ever longer than one.
Type "g"
Sleep 400ms
Type "x"
Sleep 2.2s
Type "y"
Sleep 2.5s

Type "q"
Sleep 1.2s
