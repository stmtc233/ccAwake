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

## Signing & Notarization

`scripts/build-app.sh` signs the bundle based on the `SIGN_IDENTITY` environment
variable:

- **Unset or `-`** → ad-hoc signing (`codesign --sign -`). Local development only.
  The privileged Helper daemon will **not** register with launchd under ad-hoc
  signing, so keep-awake cannot actually work. Not distributable.
- **A Developer ID Application identity** → distribution signing with a hardened
  runtime and secure timestamp (`--options runtime --timestamp`), required for
  notarization and for the `SMAppService` Helper to register.

The `Release` workflow (`.github/workflows/release.yml`) runs the full pipeline
on `v*` tags when the signing secrets are present:

1. Imports the Developer ID `.p12` into a temporary keychain and resolves the
   signing identity (falls back to ad-hoc, non-distributable, if secrets are
   absent).
2. Builds the signed bundle via `build-app.sh`.
3. Notarizes: zips with `ditto`, submits via `xcrun notarytool submit --wait`,
   staples with `xcrun stapler staple`, and verifies with `spctl -a -vvv`.
4. Packages `ccAwake-<tag>.app.zip` + `.sha256` and publishes the GitHub Release.

### Required GitHub secrets

| Secret | Purpose |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | Base64-encoded Developer ID Application cert (`.p12`) |
| `DEVELOPER_ID_P12_PASSWORD` | Password for the `.p12` |
| `KEYCHAIN_PASSWORD` | Password for the temporary CI keychain |
| `AC_APPLE_ID` | Apple ID for notarization |
| `AC_APP_PASSWORD` | App-specific password for notarization |
| `AC_TEAM_ID` | Apple Developer Team ID |

If the signing secrets are not configured, the workflow still builds and
packages an ad-hoc bundle, but marks it as not distributable.
