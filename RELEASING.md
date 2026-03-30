# Releasing Quick Markdown Viewer (Signed + Notarised)

This guide is for maintainers creating a public macOS release that follows the normal Gatekeeper trust flow (Developer ID signing + Apple notarisation).

Sensitive setup stays local by design. The repository does **not** store Team credentials, passwords, API keys, or keychain profiles.

## 1. One-time local secure setup (manual)

### 1.1 Configure your Team in Xcode

1. Open `QuickMarkdownViewer.xcodeproj` in Xcode.
2. Select target **QuickMarkdownViewer**.
3. Open **Signing & Capabilities**.
4. Under **Release**, choose your paid Apple Developer Team.
5. Keep signing **Automatic**.

This step is intentionally manual so your local account context never needs to be committed.

### 1.2 Create a local notarytool keychain profile

Run this once on your Mac (replace placeholders):

```bash
xcrun notarytool store-credentials "QMV_NOTARY" \
  --apple-id "your-apple-id@example.com" \
  --team-id "YOUR_TEAM_ID" \
  --password "app-specific-password"
```

You can then reuse `QMV_NOTARY` for release commands. Credentials are stored in your local keychain.

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

## 2. Build, sign, notarise, and package (scripted)

### 2.0 Keep Apple Help content in sync

If `README.md` changed since the previous release, refresh the Help Book copy
before packaging:

1. Update:
   - `QuickMarkdownViewer/Resources/Help/QuickMarkdownViewerHelp.help/Contents/Resources/en.lproj/index.html`
   - `QuickMarkdownViewer/Resources/Help/QuickMarkdownViewerHelp.help/Contents/Resources/index.html`
   so both copies mirror the current public `README.md` content.
2. Regenerate the Help index:

```bash
hiutil -Caf \
  QuickMarkdownViewer/Resources/Help/QuickMarkdownViewerHelp.help/Contents/Resources/QuickMarkdownViewerHelp.helpindex \
  QuickMarkdownViewer/Resources/Help/QuickMarkdownViewerHelp.help/Contents/Resources
```

This ensures the macOS Help menu search field can find up-to-date Help topics.

From repo root:

```bash
scripts/release/make_signed_release.sh --keychain-profile QMV_NOTARY
```

Optional Team override if you need it:

```bash
scripts/release/make_signed_release.sh \
  --keychain-profile QMV_NOTARY \
  --team-id YOUR_TEAM_ID
```

Equivalent environment-variable form:

```bash
TEAM_ID=YOUR_TEAM_ID \
scripts/release/make_signed_release.sh --keychain-profile QMV_NOTARY
```

## 3. What the scripts do

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

## 4. Output artefacts

After a successful run:

- `dist/export/Quick Markdown Viewer.app`
- `dist/release/QuickMarkdownViewer-macOS.zip`
- `dist/release/QuickMarkdownViewer-macOS-SHA256.txt`

## 5. GitHub release upload checklist

1. Create a new GitHub Release for the version tag.
2. Upload:
   - `QuickMarkdownViewer-macOS.zip`
   - `QuickMarkdownViewer-macOS-SHA256.txt`
3. In release notes, state that this build is officially signed and notarised.

## 6. Troubleshooting

- If archive/export fails with signing errors:
  - Recheck Team selection in Xcode for **Release**.
  - If local Team auto-resolution is unavailable, rerun the release command with `--team-id YOUR_TEAM_ID` or `TEAM_ID=YOUR_TEAM_ID`.
  - Ensure your Apple Developer membership is active.
- If notarisation fails:
  - Recheck local keychain profile (`xcrun notarytool history --keychain-profile QMV_NOTARY`).
  - Confirm the app bundle identifier and signing identity are consistent.
