# Release

Infinity Hub is distributed outside the Mac App Store with Developer ID signing, Hardened Runtime, Apple notarization, and GitHub Releases.

## Prerequisites

- The `Infinity Hub` scheme is shared and committed.
- `MARKETING_VERSION` contains the user-facing version.
- `CURRENT_PROJECT_VERSION` contains a globally increasing build number.
- `.github/release-notes.md` describes the user-visible changes.
- `APPLE_TEAM_ID` and the release secrets are configured in GitHub.
- The release commit is on `main` and ready to tag.

## Publish

Create and push a tag that exactly matches the Xcode versions:

```bash
git tag vX.Y.Z-build.N
git push origin vX.Y.Z-build.N
```

The workflow rejects mismatched tags. A successful run archives Infinity Hub, signs it with Developer ID, submits it to Apple's notary service, staples the ticket, validates it with Gatekeeper, and uploads the notarized ZIP plus a SHA-256 checksum.

## Retry

Use the Release workflow's manual dispatch with the existing tag. A successful retry replaces the existing assets without creating a second tag.
