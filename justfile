# The build is quiet and its output goes to stderr, so the picker owns stdout
# from its first frame — a "Compiling…" line printed into the alternate screen
# would be scrolled away by the first redraw anyway, but a *piped* run
# (`just swp -l | grep`) would have it in the data.

# Run swp from a debug build: `just swp`, `just swp 3000`, `just swp -l node`
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

# Make sure ~/.local/bin is on your PATH (add to ~/.zshrc / ~/.bashrc if not):
#   export PATH="$HOME/.local/bin:$PATH"

# Build release and symlink it into ~/.local/bin (no sudo)
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

# Build the universal macOS binary the release ships (arm64 + x86_64)
build-universal:
    swift build -c release --arch arm64 --arch x86_64
    @file "$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/swp"

# Catches Linux-only compile errors (#if canImport, Glibc spellings, corelibs
# API gaps) without leaving macOS. The build dir lives in a named volume so
# rebuilds stay incremental. Requires Docker.
#
# Worth running before a release: swp's Linux scanner and its socket test are
# never compiled by a macOS build, so CI is otherwise the first to find out.

# Build for Linux in a container (requires Docker)
linux-build:
    docker run --rm -v "$PWD":/src -w /src -v swp-linux-build:/build \
      swift:6.2 bash -c "swift build --build-tests --build-path /build"

# Build, test and run the integration checks for Linux in a container
linux-test:
    docker run --rm -v "$PWD":/src -w /src -v swp-linux-build:/build \
      swift:6.2 bash -c "swift build --build-path /build && swift test --build-path /build && ./Tests/Integration/cli.sh /build/debug/swp"

# Everything a release runs, locally: format, lint, tests, and Linux
preflight: check linux-test
    @echo "Preflight clean. Next: bump Sources/swp/Version.swift, update CHANGELOG.md, then `just tag`."

# The version comes from Version.swift, so the tag and the binary can never
# disagree — the release workflow rejects a tag that does not match it anyway,
# and this catches it before the push rather than after.

# Verify, tag and push — this is what starts the release workflow
tag:
    #!/usr/bin/env bash
    set -euo pipefail
    version=$(grep -oE 'let appVersion = "[^"]+"' Sources/swp/Version.swift | head -n1 | sed -E 's/.*"([^"]+)".*/\1/')
    if [ -n "$(git status --porcelain)" ]; then
      echo "error: working tree is dirty — commit first." >&2; exit 1
    fi
    if ! grep -q "^## \[$version\]" CHANGELOG.md; then
      echo "error: CHANGELOG.md has no '## [$version]' section." >&2; exit 1
    fi
    if git rev-parse "v$version" >/dev/null 2>&1; then
      echo "error: tag v$version already exists." >&2; exit 1
    fi
    echo "Tagging v$version"
    git tag -a "v$version" -m "swp $version"
    git push origin "v$version"
    echo "Pushed. Watch it with: gh run watch --repo dsaad68/swp"

# Renders demo/demo.gif from demo/swp.tape. Stands up three disposable
# listeners first and tears them down after, because the tape ends by killing
# one of them. Needs vhs (brew install vhs), which pulls ttyd and ffmpeg.

# Record the README demo GIF
demo:
    #!/usr/bin/env bash
    set -euo pipefail
    command -v vhs >/dev/null || { echo "error: vhs not installed (brew install vhs)" >&2; exit 1; }
    swift build -c release
    trap './demo/teardown.sh' EXIT
    ./demo/setup.sh
    PATH="$PWD/.build/release:$PATH" vhs demo/swp.tape
    ls -lh demo/demo.gif

# Clean build artifacts
clean:
    swift package clean
