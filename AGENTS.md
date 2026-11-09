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
- release-please (`.github/workflows/release.yml`) keeps a release pull request open from the Conventional Commits:
  `feat` bumps the minor version, `fix` the patch (before 1.0, a breaking `!` bumps the minor). Merging it tags
  `vX.Y.Z`, updates `CHANGELOG.md` and the version strings marked `x-release-please-version`, and creates the GitHub
  Release with its notes. Don't edit versions or the changelog by hand.
