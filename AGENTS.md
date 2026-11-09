# AGENTS.md

Instructions for coding agents (and humans) working on TelemetryKit for Swift.

## Commits
- Conventional Commits (`feat:`, `fix:`, `docs:`, `test:`, `refactor:`, `ci:`, `build:`, `chore:`; `!` for breaking).
- **No `Co-Authored-By` or other trailers** in commit messages, whatever a tool's default is.
- Keep commits focused; update `CHANGELOG.md` for user-visible changes.

## Code
- Swift 6 language mode with strict concurrency; no new warnings.
- No third-party dependencies. Foundation only; UIKit only behind `#if canImport(UIKit)`.
- Nothing app-specific in the library: endpoints, names, keys and limits are `TelemetryClient.Configuration`.
- Privacy first: every free string is scrubbed (`TelemetryScrub`) before it is queued; keep the scrub failing closed.
- The wire format is the Grafana Faro receiver's JSON (`FaroPayload`); keep it compatible with Alloy's `faro.receiver`.

## Checks
- `swift build` and `swift test` must pass (Swift Testing).
- `swiftlint lint` when SwiftLint is installed; fix code rather than adding inline suppressions.
- CI: GitHub Actions (`.github/workflows/ci.yml`).

## Releases
- Development happens on the maintainers' own Git server; GitHub is the public mirror. Releases are cut there by a
  release job, never on GitHub: it derives the next version from the Conventional Commits since the last `vX.Y.Z` tag
  (`feat` bumps the minor version, `fix`/`perf` the patch; before 1.0 a breaking `!` bumps the minor), writes the
  `CHANGELOG.md` section and the version strings marked `x-release-please-version`, commits `chore(release): vX.Y.Z`,
  tags, runs the tests and, after an approval, pushes to GitHub and creates the GitHub Release with the notes.
- Don't edit versions or the changelog by hand, and keep the version markers.
- Contributions on GitHub are welcome as pull requests; maintainers bring merged changes into the main repository.
