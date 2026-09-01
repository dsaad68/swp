# Run swp from a debug build. `just swp`, `just swp 3000`, `just swp -l node`
#
# The build is quiet and its output goes to stderr, so the picker owns stdout
# from its first frame — a "Compiling…" line printed into the alternate screen
# would be scrolled away by the first redraw anyway, but a *piped* run
# (`just swp -l | grep`) would have it in the data.
swp *ARGS:
    @swift build >&2
    @.build/debug/swp {{ARGS}}

# Build the project
build:
    swift build

# Build in release mode
build-release:
    swift build -c release

# Run the release binary
run-release *ARGS:
    .build/release/swp {{ARGS}}

# Build release, copy to ./Release/, and symlink into ~/.local/bin (no sudo).
# Make sure ~/.local/bin is on your PATH (add to ~/.zshrc / ~/.bashrc if not):
#   export PATH="$HOME/.local/bin:$PATH"
install:
    swift build -c release
    mkdir -p Release
    cp .build/release/swp Release/swp
    mkdir -p "$HOME/.local/bin"
    ln -sf "$(pwd)/Release/swp" "$HOME/.local/bin/swp"
    @echo "Installed to $HOME/.local/bin/swp"
    @echo "Make sure ~/.local/bin is on your PATH."

# Run tests
test:
    swift test

# Format the code in place (SwiftFormat)
format:
    swiftformat .

# Check formatting without modifying files (used in CI)
format-check:
    swiftformat --lint .

# Lint the code (SwiftLint); --strict matches CI (warnings fail)
lint:
    swiftlint lint --strict

# Auto-fix what the tools can, then format
lint-fix:
    swiftlint lint --fix
    swiftformat .

# Run every check the way CI does: formatting, lint, tests
check: format-check lint test

# Run the CLI integration checks against a debug build
integration: build
    ./Tests/Integration/cli.sh .build/debug/swp

# Clean build artifacts
clean:
    swift package clean
