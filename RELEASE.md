# Release Notes

## GitHub Actions

This repository has two workflows:

- `CI`: runs on pushes, pull requests, and manual dispatch. It runs tests, validates localization files, builds the app bundle, and verifies the expected bundle files.
- `Release`: runs on tags matching `v*` or manual dispatch with an existing tag. It builds `ccAwake.app`, packages it as a zip, writes a SHA-256 checksum, uploads the workflow artifact, and creates or updates the GitHub Release.

## Creating a Release

```sh
git tag v0.1.0
git push origin v0.1.0
```

The release workflow publishes:

- `ccAwake-v0.1.0.app.zip`
- `ccAwake-v0.1.0.app.zip.sha256`

## Signing

The current build script uses ad-hoc signing:

```sh
codesign --force --sign -
```

This is enough for CI packaging and local testing, but it is not Developer ID signing or notarization. For public distribution outside GitHub source builds, add Developer ID signing and Apple notarization before marking a release as production-ready.
