# Agent Instructions

## Working Style

- Discuss diagnosis and options before editing when the user asks a question or reports a symptom.
- Implement changes only after explicit approval.
- Do not push, publish a release, create or update a pull request, or merge without explicit approval.
- Preserve unrelated local changes in a dirty worktree.

## Xcode Validation

- Prefer Xcode's Issue Navigator for compiler diagnostics.
- After code changes, refresh Issue Navigator first.
- Run a full build when explicitly requested, when Issue Navigator is stale or insufficient, or when new files and cross-target changes require compile confidence.
- Keep the `Infinity Hub` archive scheme shared and committed.

## Git

- Use Conventional Commits with a concise bullet-list body.
- Do not add AI attribution to commits, pull requests, or review comments.
- Keep local branches private until the user explicitly asks to push or open a pull request.

## Releases

- User-facing changes require a new `MARKETING_VERSION` and an incremented `CURRENT_PROJECT_VERSION`.
- Build-only releases increment only `CURRENT_PROJECT_VERSION`.
- Prepare release changes in a dedicated `chore: release vX.Y.Z` commit.
- Release tags use `vX.Y.Z-build.N` and must match the Xcode project values.
- Update `.github/release-notes.md` with user-facing language before tagging.
- A tag push triggers a Developer ID-signed, notarized GitHub Release.

## Architecture

- Keep hardware access read-only unless an explicitly reviewed feature requires a write.
- Preserve device identity, connection priority, grouping, and retention rules in the service or view-model layer rather than duplicating them in SwiftUI views.
- Keep private protocol discoveries and verified device behavior documented under `Docs/`.
- Do not broaden HID matching, Bluetooth services, or requested macOS permissions without explicit approval and device verification.
