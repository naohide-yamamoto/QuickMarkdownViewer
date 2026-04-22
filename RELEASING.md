# Releasing Stillic (Signed + Notarised)

This guide is for maintainers creating a public macOS release that follows the normal Gatekeeper trust flow (Developer ID signing + Apple notarisation).

Sensitive setup stays local by design. The repository does **not** store Team credentials, passwords, API keys, or keychain profiles.

## 1. One-time local secure setup (manual)

### 1.1 Configure your Team in Xcode

1. Open `Stillic.xcodeproj` in Xcode.
2. Select target **Stillic**.
3. Open **Signing & Capabilities**.
4. Under **Release**, choose your paid Apple Developer Team.
5. Keep signing **Automatic**.

This step is intentionally manual so your local account context never needs to be committed.

### 1.2 Create a local notarytool keychain profile

Run this once on your Mac (replace placeholders):

```bash
xcrun notarytool store-credentials "STILLIC_NOTARY" \
  --apple-id "your-apple-id@example.com" \
  --team-id "YOUR_TEAM_ID" \
  --password "app-specific-password"
```

You can then reuse `STILLIC_NOTARY` for release commands. Credentials are stored in your local keychain.

### 1.3 Enable local Git safety hooks

This repository includes local Git hooks that block accidental commits/pushes
of Team/provisioning metadata and local release artefacts.

Run once per clone:

```bash
scripts/git/install_local_hooks.sh
```

Important:
- run this again after cloning on another machine
- use normal `git commit` and `git push` so hooks run automatically
- avoid `--no-verify` for normal workflows because it bypasses the hooks

## 2. Prepare release content before tagging

Before building or tagging a release:

1. Update release-facing source files as needed:
   - `CHANGELOG.md`
   - `README.md`
   - `README.developers.md`
   - app version metadata (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`; these feed `CFBundleShortVersionString` and `CFBundleVersion`)
2. If `README.md` changed, refresh the bundled Help Book copy:
   - `Stillic/Resources/Help/StillicHelp.help/Contents/Resources/en.lproj/index.html`
   - `Stillic/Resources/Help/StillicHelp.help/Contents/Resources/index.html`
3. Regenerate the Help index:

```bash
hiutil -Caf \
  Stillic/Resources/Help/StillicHelp.help/Contents/Resources/StillicHelp.helpindex \
  Stillic/Resources/Help/StillicHelp.help/Contents/Resources
```

If `README.md` did not change, you can skip steps 2 and 3.

4. Commit all release-content changes together.
5. Create or update the release tag only after that final release-content commit.

This ensures the tagged source matches the released app content, including bundled Help.

## 3. Build, sign, notarise, and package (scripted)

From repo root, after the final release-content commit and tag preparation:

```bash
scripts/release/make_signed_release.sh --keychain-profile STILLIC_NOTARY
```

Optional Team override if you need it:

```bash
scripts/release/make_signed_release.sh \
  --keychain-profile STILLIC_NOTARY \
  --team-id YOUR_TEAM_ID
```

Equivalent environment-variable form:

```bash
TEAM_ID=YOUR_TEAM_ID \
scripts/release/make_signed_release.sh --keychain-profile STILLIC_NOTARY
```

## 4. What the scripts do

- `scripts/release/archive_and_export.sh`
  - Builds a Release archive.
  - Exports a signed `.app` using Developer ID method.
- `scripts/release/notarise_and_package.sh`
  - Zips the app bundle.
  - Submits ZIP to Apple notary service and waits for result.
  - Staples notarisation ticket to the app.
  - Runs Gatekeeper validation.
  - Writes SHA256 checksum.
- `scripts/release/make_signed_release.sh`
  - Runs both scripts in order.

## 5. Output artefacts

After a successful run:

- `dist/export/Stillic.app`
- `dist/release/Stillic-v<version>-macOS.zip`
- `dist/release/Stillic-v<version>-macOS-SHA256.txt`

## 6. GitHub release upload checklist

1. Create a new GitHub Release for the version tag.
2. Upload:
   - `Stillic-v<version>-macOS.zip`
   - `Stillic-v<version>-macOS-SHA256.txt`
3. In release notes, state that this build is officially signed and notarised.

## 7. Troubleshooting

- If archive/export fails with signing errors:
  - Recheck Team selection in Xcode for **Release**.
  - If local Team auto-resolution is unavailable, rerun the release command with `--team-id YOUR_TEAM_ID` or `TEAM_ID=YOUR_TEAM_ID`.
  - Ensure your Apple Developer membership is active.
- If notarisation fails:
  - Recheck local keychain profile (`xcrun notarytool history --keychain-profile STILLIC_NOTARY`).
  - Confirm the app bundle identifier and signing identity are consistent.
