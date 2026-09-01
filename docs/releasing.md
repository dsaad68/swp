# Releasing swp

The whole ceremony is a tag. Everything else derives from it.

```sh
just preflight        # format, lint, tests, and Linux in a container
# bump Sources/swp/Version.swift, write the CHANGELOG section, commit
just tag              # verifies, tags, pushes — this starts the release
gh run watch --repo dsaad68/swp
```

Users then get it with:

```sh
brew install dsaad68/tap/swp
brew upgrade swp
```

---

## One-time setup

The release publishes to a **separate repository**,
[dsaad68/homebrew-tap](https://github.com/dsaad68/homebrew-tap), so the default
`GITHUB_TOKEN` cannot reach it. It needs a token with write access to the tap:

1. Create a fine-grained personal access token scoped to `dsaad68/homebrew-tap`
   with **Contents: Read and write**.
2. Add it to this repository as a secret named **`HOMEBREW_TAP_TOKEN`**
   (`gh secret set HOMEBREW_TAP_TOKEN --repo dsaad68/swp`).

Without it the release still publishes — the workflow emits a warning and skips
only the tap step, so a missing secret costs you a `brew` bump, not a release.

## What a tag actually runs

`.github/workflows/release.yml`, in four gates. Each one must pass before the
next starts, so a bad release stops at the cheapest point that can catch it.

**1. `verify-version`** — the tag must match `appVersion` in
`Sources/swp/Version.swift`. This runs first because it costs seconds and
catches the most common mistake. A binary that reports a different version than
its own formula is worse than no release: the formula's `test do` block asserts
on that exact string, so the mismatch would surface on a *user's* machine during
`brew install`.

**2. `verify-quality`** — build, `swift test` and the CLI integration checks, on
macOS and Linux, *on the tagged commit*. CI having been green on the branch is
not the same thing: a tag can point anywhere, including at a commit that never
saw CI.

**3. `build`** — the artifacts users download.

| | built on | artifact |
| --- | --- | --- |
| macOS | `macos-14`, `--arch arm64 --arch x86_64` | `swp-vX.Y.Z-macos.tar.gz` (universal) |
| Linux | `swift:6.2` container | `swp-vX.Y.Z-linux-x86_64.tar.gz` |

Note that a universal build lands in `.build/apple/Products/Release`, not the
usual `.build/release` — which is why the packaging step asks
`--show-bin-path` with the *same* flags rather than assuming a path.

**4. `release`** — computes SHA-256 sums, creates the GitHub Release with notes
extracted from the matching `CHANGELOG.md` section, then renders
`.github/homebrew/swp.rb.template` into `Formula/swp.rb` in the tap and pushes.

> **Release notes go to a file, never to a command line.** The first version of
> this workflow passed them as `--notes "${{ steps.notes.outputs.body }}"`.
> Actions substitutes an expression *textually into the script* before bash sees
> it, so 129 lines of changelog Markdown became shell source — and every
> `` `inline code span` `` in it is a backtick pair, which bash ran as a command
> substitution. The log filled with `swp: command not found`, and what survived
> blew past `ARG_MAX`. It failed loudly, which was luck: the content was ours.
> A changelog entry containing `$(...)` would have executed inside the one job
> that holds the tap token.
>
> The rule this leaves: **`${{ }}` belongs in `env:`, not in a `run:` body.**
> The only exception in this workflow is `matrix.build`, which *is* a command
> and is a literal written a few lines above its use.

Two guards in that last step, both for failures that would otherwise land on a
user rather than in the log:

- a missing or empty artifact fails the job, rather than publishing a formula
  with an empty `sha256` that `brew` reports as a checksum mismatch;
- any `__PLACEHOLDER__` left after substitution fails the job, rather than
  shipping a formula that cannot parse.

## The formula

`.github/homebrew/swp.rb.template` is the source of truth. **Never edit
`Formula/swp.rb` in the tap** — the next release overwrites it. The template
carries that warning in its own header comment, since that is where someone
would be standing when they were about to.

Its `test do` block runs on `brew install --build-from-source` and in the tap's
own CI:

```ruby
assert_match "swp __VERSION__", shell_output("#{bin}/swp --version")
assert_match "PORT", shell_output("#{bin}/swp -l -a")
```

The second uses `-a` deliberately: a build machine may well have nothing
listening, and an empty match is a deliberate exit 1, which would fail the test
for the wrong reason.

## Checklist

- [ ] `just preflight` is clean (this includes Linux — see below)
- [ ] `Sources/swp/Version.swift` bumped
- [ ] `CHANGELOG.md` has a `## [X.Y.Z]` section, dated
- [ ] committed and pushed, CI green on `main`
- [ ] `just tag`

## Run the Linux checks before you tag

swp's Linux scanner is behind `#if !canImport(Darwin)`, so **a macOS build never
compiles it**. Neither does it compile the platform-specific corners of the test
suite. This is not hypothetical: CI's Linux job failed on every commit from the
first one until someone looked, because `SOCK_STREAM` is an `Int32` in Darwin's
headers and a `__socket_type` in Glibc's, and `Darwin.bind` compiles nowhere
else.

```sh
just linux-build      # compile only, fastest
just linux-test       # build + test + integration checks
```

Both need Docker running. `just preflight` includes `linux-test`.

## If a release goes wrong

**The tag was wrong.** Delete it locally and remotely, fix, tag again:

```sh
git tag -d v0.2.0 && git push origin :refs/tags/v0.2.0
```

Do this only before anyone has installed it. A published version that people
have downloaded should be superseded by a new patch version, not rewritten —
Homebrew caches by URL and checksum, and moving a tag under a released formula
gives users a checksum mismatch they cannot resolve.

**The publish step failed.** Check whether it got as far as creating the
release: `gh release list --repo dsaad68/swp`. The tap is only touched after the
release succeeds, so a failure at or before that point has published nothing,
and re-tagging is safe. That is what happened on the first attempt at v0.1.0 —
the tag was deleted and re-pushed once the workflow was fixed, with no release
and no tap commit to clean up.

**The build failed after the release was created.** The GitHub Release exists
with partial assets. Delete it (`gh release delete v0.2.0 --repo dsaad68/swp`),
fix, and re-tag — the release job is the last gate, so nothing has reached the
tap yet.

**The tap was not updated.** Check that `HOMEBREW_TAP_TOKEN` is set and still
valid; the job warns rather than failing when it is missing. Re-running just
that job is safe — it is idempotent, and exits cleanly when the formula is
already current.
