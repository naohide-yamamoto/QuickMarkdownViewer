# Quick Markdown Viewer

Quick Markdown Viewer is a native Markdown viewer for macOS.

It is designed to feel like Preview for Markdown:
- Double-click a Markdown file
- Open immediately in a rendered document window
- No source pane and no editing UI

Current release: `v1.1.0`.

## Contents

- [Scope](#scope)
- [Non-goals](#non-goals)
- [Build and Run](#build-and-run)
- [Signed Release Workflow (Paid Team)](#signed-release-workflow-paid-team)
- [Git Safety Hooks (Per-Clone Setup)](#git-safety-hooks-per-clone-setup)
- [System Requirements](#system-requirements)
- [Associate Markdown Files](#associate-markdown-files)
- [Supported File Extensions](#supported-file-extensions)
- [Markdown Compatibility](#markdown-compatibility)
- [Local Rendering and Security Model](#local-rendering-and-security-model)
- [Licence](#licence)
- [Official Builds and Forks](#official-builds-and-forks)
- [No Warranty](#no-warranty)
- [Known Issues](#known-issues)
- [Notes](#notes)
- [Signed Release Readiness Checklist](#signed-release-readiness-checklist)

## Scope

Quick Markdown Viewer v1 is intentionally viewer-first:
- macOS only (Swift + SwiftUI)
- `WKWebView` rendering surface
- Bundled local `markdown-it` renderer (no CDN)
- Bundled local `highlight.js` syntax highlighter (no CDN)
- One document per window
- File open, drag/drop, and Finder association
- Native recent-documents menu (`File > Open Recent`)
- Native file sharing (`File > Share` and toolbar Share item)
- Rendered print and PDF export commands
- Configurable view-source handoff (`Settings > General > View source with`) with fallback to the system default text editor
- Native speech controls (`Edit > Speech`)
- Native customisable AppKit toolbar (`NSToolbar`) with persisted item layout/display mode
- Toolbar hide/show (`⌥⌘T`) and toolbar customisation (`View > Customise Toolbar…`)
- Compact native Find panel when toolbar search is unavailable (for example, toolbar hidden)
- Native Settings window with General/Appearance panes
- Built-in document text controls in Settings:
  - typeface (`Sans-serif`, `Serif`)
  - density (`Standard`, `Compact`)
  - local-only implementation (bundled CSS/font stack only; no external CSS/font loading)
- Manual `Check for Updates…` plus optional automatic release-metadata checks

## Non-goals

Quick Markdown Viewer is **not**:
- a Markdown editor
- a split-view preview editor
- a notes app or knowledge base
- a file browser or tabbed workspace
- an IDE-style tool

No live preview, plugin system, command palette, or sync features are included.

## Build and Run

1. Open [QuickMarkdownViewer.xcodeproj](QuickMarkdownViewer.xcodeproj) in Xcode (current technical project filename).
2. Select the current `QuickMarkdownViewer` scheme (current technical scheme name).
3. Choose **My Mac** as the macOS target.
4. Build and run (`⌘R`).

The project/scheme names above are current technical names.

For public source builds, the shared `Debug` configuration is set up to be as low-friction as possible. On many Macs, opening the project and pressing `⌘R` should be enough. If Xcode asks about signing on first launch, choose the local run-signing option if offered, or select your own Personal Team in Xcode and run again.

Minimum tested deployment target in project settings is macOS 13.

## Signed Release Workflow (Paid Team)

If you have a paid Apple Developer Program membership and want public builds that pass the normal Gatekeeper flow, use the included release scripts.

Manual local-only steps (kept out of Git for security):
- Set your Apple Developer Team in Xcode for **Release** signing.
- Store a local notarytool keychain profile on your machine.

Scripted release path:

```bash
scripts/release/make_signed_release.sh --keychain-profile QMV_NOTARY
```

If local Team auto-resolution does not work on your machine, rerun with an
explicit Team override:

```bash
scripts/release/make_signed_release.sh --keychain-profile QMV_NOTARY --team-id YOUR_TEAM_ID
```

This produces:
- a signed exported app bundle in `dist/export`
- a notarised ZIP and SHA256 checksum in `dist/release`
  - `QuickMarkdownViewer-v<version>-macOS.zip`
  - `QuickMarkdownViewer-v<version>-macOS-SHA256.txt`

Full instructions are in [RELEASING.md](RELEASING.md).

## Git Safety Hooks (Per-Clone Setup)

To reduce the chance of accidentally committing local signing metadata, this
repository includes local Git safety hooks.

Hook files tracked in the repository:
- `.githooks/pre-commit`
- `.githooks/pre-push`
- `scripts/git/install_local_hooks.sh`

Install once per local clone:

```bash
scripts/git/install_local_hooks.sh
```

Verify that hooks are active:

```bash
git config --get core.hooksPath
```

Expected output:

```text
.githooks
```

What the hooks enforce:
- `pre-commit` blocks staged local build/export artefacts (`dist/*`, `*.xcarchive*`).
- `pre-commit` blocks newly added `DEVELOPMENT_TEAM` or provisioning profile
  lines in `QuickMarkdownViewer.xcodeproj/project.pbxproj`.
- `pre-push` blocks pushes if `project.pbxproj` contains committed
  `DEVELOPMENT_TEAM` metadata.
- `pre-push` blocks pushes if `dist/` is tracked in Git.

Working rules:
- Use normal `git commit` and `git push` so hooks run automatically.
- Avoid `--no-verify` for normal workflows because it bypasses hooks.
- If you clone this repository on another machine, run
  `scripts/git/install_local_hooks.sh` again on that machine.

## System Requirements

This section is maintained as Quick Markdown Viewer evolves, and should be reviewed at each release.

### Minimum

- macOS 13.0 (Ventura) or newer.
- Mac hardware primarily targeted at Apple Silicon (`M1` or newer).
- 8 GB unified memory (practical baseline).
- No external runtime dependency or network dependency to render local Markdown files.

### Recommended

- Apple Silicon Mac (`M1`/`M2`/`M3` or newer).
- 16 GB unified memory for larger documents, many local images, or multiple open windows.
- Latest stable macOS release for best `WKWebView` behaviour.

### Dependencies

- Runtime rendering stack:
  - `WKWebView` (system WebKit on macOS).
  - Bundled local `markdown-it` (`QuickMarkdownViewer/Web/markdown-it.min.js`, current technical source path).
  - Bundled local `highlight.js` (`QuickMarkdownViewer/Web/highlight.min.js`) for optional fenced-code syntax highlighting.
  - Bundled local renderer/template assets (`index.html`, `renderer.js`, `styles.css`).
- Build dependency:
  - Xcode (for local build/run from source).
- Distribution/signing (optional, only for smooth signed public distribution):
  - Apple Developer Team/account for Developer ID signing and notarisation.
  - Local keychain profile configured for `xcrun notarytool`.

### Debug Launch Note (Xcode 26.3)

If `WKWebView` helper processes crash while debugging, disable debugger launch injection:

1. Open `Product > Scheme > Edit Scheme...`
2. Select **Run**.
3. In **Info**, untick **Debug executable**.
4. Run again with `⌘R`.

## Associate Markdown Files

From the app:

1. Open Quick Markdown Viewer.
2. Open Settings (`⌘,`).
3. In the General pane, choose `Quick Markdown Viewer` as the default Markdown viewer.

From Finder:

1. In Finder, select a `.md` file and press `⌘I`.
2. In **Open with**, choose `Quick Markdown Viewer`.
3. Click **Change All…** to make it default for that extension.
4. Repeat for `.markdown`, `.mdown`, `.mkd`, `.mkdn`, or `.mdwn` if needed.

## Supported File Extensions

Quick Markdown Viewer currently accepts:
- `.md`
- `.markdown`
- `.mdown`
- `.mkd`
- `.mkdn`
- `.mdwn`

Selecting Quick Markdown Viewer as the default Markdown viewer in Settings (`⌘,`) updates the Launch Services handler for the primary Markdown content type. On current macOS builds, this is confirmed once and applied to grouped Markdown extensions (observed: `.md` and `.markdown`).

Quick Markdown Viewer intentionally does **not** support:
- `.rmd`
- `.qmd`

Unsupported-file warning behaviour:
- `.rmd` and `.qmd` show specific explanatory warnings.
- Other unsupported file types show a generic warning listing accepted extensions.

## Markdown Compatibility

Quick Markdown Viewer aims for standard document-style Markdown rendering via
the bundled `markdown-it` pipeline. More specifically, the rendering target is
the CommonMark-oriented behaviour provided by `markdown-it`, together with the
small set of enabled features and local handling rules used by this app. Quick
Markdown Viewer is not intended to reproduce non-standard or modified Markdown
formats, platform-specific rendering rules, or special README-style
conveniences. The within-document table-of-contents links in [README.md](README.md)
and [README.developers.md](README.developers.md) are examples of behaviour that
may work on a hosting platform without being a Quick Markdown Viewer
compatibility target.

Fenced-code syntax highlighting is optional: when enabled in
Settings, the app applies bundled `highlight.js` after `markdown-it` renders
document HTML. The default highlight theme is
GitHub (light/dark), with VS Code, Atom One, and Stack Overflow theme families
also bundled for selection in Settings. For print and PDF export, syntax
highlighting always resolves to the selected theme’s light variant so output
remains print-friendly regardless of the active app appearance mode.

## Local Rendering and Security Model

Quick Markdown Viewer uses a local rendering pipeline. Markdown source is
converted into an app-controlled HTML document using bundled `markdown-it`,
bundled `highlight.js` (optional), bundled CSS, and bundled renderer
JavaScript, then loaded into `WKWebView`.
Document text controls (typeface and density) are also applied from bundled
local CSS/font stacks only, without loading external CSS or fonts.
The app does not use a remote Markdown rendering API or upload document
contents for normal viewing.

The HTML shell applies a restrictive Content Security Policy, including
`connect-src 'none'`, so normal rendering does not perform network fetches.
Local relative images and local Markdown links are resolved on-device. Raw HTML
passthrough from Markdown input is disabled in the renderer configuration.

External `http`, `https`, and `mailto` links are opened only when the user
explicitly clicks them, at which point they are handed off to the system
browser or mail app rather than rendered inside Quick Markdown Viewer.

Update checks follow the same opt-in principle:
- `Check for Updates…` performs a user-initiated request to GitHub for release metadata.
- Automatic update checking is off by default.
- If users enable automatic checking in Settings, Quick Markdown Viewer contacts GitHub only to fetch release metadata and does not download/install updates automatically.

## Licence

Quick Markdown Viewer source code is licensed under the Apache License,
Version 2.0.

See [LICENSE](LICENSE) for the full licence text.
Project attribution details are provided in [NOTICE](NOTICE).

The Quick Markdown Viewer name, app icon, and related branding are not
licensed under Apache-2.0. See [TRADEMARKS.md](TRADEMARKS.md).

Bundled third-party software notices are provided in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Official Builds and Forks

Quick Markdown Viewer is open-source software. You are welcome to read the
code, build it, fork it, and modify it under the terms of the Apache License,
Version 2.0.

Official public builds are only those released by Naohide Yamamoto through this
repository's Releases page and signed/notarised by Naohide Yamamoto.

If you obtain Quick Markdown Viewer from another source, or from a fork, treat
that build as unofficial unless it is clearly identified as an official
release from this repository and carries the expected signing/notarisation
status.

If you redistribute a modified build, please rename the app and replace the
icon and related branding unless you have explicit permission to use the
official Quick Markdown Viewer branding.

## No Warranty

Quick Markdown Viewer is provided under the Apache License, Version 2.0 on an
'AS IS' basis, without warranties or conditions of any kind.

You are responsible for reviewing, building, and using the software at your
own risk.

## Known Issues

- Native macOS Help Viewer integration is currently unreliable on some systems.
  - Symptom: selecting `Help > Quick Markdown Viewer Help` can show 'The selected content is currently unavailable'.
  - Current status: Help-book registration and anchor-dispatch logs can still report success while Help Viewer fails to render content.
  - Current workaround implemented in-app: the Help menu command opens bundled in-app Help content directly.
  - Future work: revisit Apple Help Book rendering path and restore reliable native Help Viewer page loading.
- Native toolbar customisation behaviour still has deferred issues.
  - Symptom: right-clicking an existing toolbar item may not show `Remove Item`.
  - Current status: this issue persists after multiple AppKit-side adjustments (`toggleToolbarShown`, item-group tuning, and toolbar item navigation flags).
  - Current workaround: users can still remove/rearrange toolbar items via `View > Customise Toolbar…`.
  - Symptom: `Flexible Space` may not visibly expand/contract with window width changes in some toolbar layouts.
  - Current status: observed in Quick Markdown Viewer and also in Preview (v11.0 on macOS 26.3.1), suggesting AppKit/system-style behaviour rather than app-specific layout logic.
  - Current workaround: if fixed-width spacing is needed, users can insert multiple `Space` items in toolbar customisation.
  - Future work: revisit toolbar implementation details (especially grouped-item composition and style interactions) in a dedicated future pass.
- App-menu `Settings…` icon may still appear as generic `gear` on some macOS builds.
  - Symptom: menu shows `gear` even when Quick Markdown Viewer requests `gearshape`.
  - Current status: persists after switching to `SettingsLink` and applying AppKit menu-item icon overrides at launch/activation.
  - Current workaround: functional impact is none (menu action and shortcut still work); this is visual-only.
- Markdown default-app association UI can lag when changed externally.
  - Symptom: with Quick Markdown Viewer Settings already open, changing `.md` association in Finder `Get Info` may not immediately refresh the picker; likewise, with Finder `Get Info` already open, changing association in Quick Markdown Viewer may not immediately refresh Finder's displayed app.
  - Current status: actual Launch Services association is updated correctly, but already-open UI panels can display stale values until refreshed/reopened.
  - Current workaround: close/reopen the affected pane/window to refresh displayed association state.
  - Assessment: treated as a macOS/Launch Services UI refresh boundary, not an app-specific association-write failure.

## Notes

- External links (`http`, `https`, `mailto`) open in default apps.
- Local Markdown links open in a new Quick Markdown Viewer window.
- Relative image links resolve from the opened document's folder.
- File commands:
  - `⌘O` opens a Markdown file.
  - `File > Open Recent` opens recently viewed Markdown files.
  - `File > Share` opens native macOS sharing services for the current file.
  - `⌘P` prints rendered Markdown content.
  - `File > Export as PDF…` exports rendered Markdown content as PDF.
  - `File > View Source` opens the raw `.md` in the app selected in `Settings > General > View source with` (with fallback to the system default text editor if the selected app is unavailable).
  - `Quick Markdown Viewer > Check for Updates…` checks GitHub release metadata.
- Settings commands:
  - `⌘,` opens the Settings window.
  - `General` pane controls default Markdown viewer, View Source app selection, manual/automatic update-check preferences, and reset actions.
  - `Appearance` pane controls window-background size/colour.
  - `Reset All Settings` in General restores all settings across panes.
- Speech commands:
  - `Edit > Speech > Start Speaking` reads selected text, or full document text if nothing is selected.
  - `Edit > Speech > Stop Speaking` stops active speech for the current window.
- In-document search shortcuts:
  - `⌘F` focuses toolbar search when toolbar search is available.
  - With toolbar hidden (or Search shown as text-only action), `⌘F` opens a compact native Find panel.
  - `⌘G` moves to the next match.
  - `Shift+⌘G` moves to the previous match.
  - `⌘E` uses current selection for Find.
  - Search mode can be switched between case-insensitive and case-sensitive from the find-field magnifier menu.
- Zoom shortcuts:
  - `⌘=` (or `⌘` + `+`) zooms in.
  - `⌘-` zooms out.
  - `⌘0` resets to actual size (100%).
  - `⌘9` applies one-way zoom to fit for the current window width (repeating it at fit causes no further zoom change).
  - Trackpad pinch follows the same zoom range model as keyboard zoom.
  - Trackpad smart magnify (two-finger double tap) follows the same one-way zoom-to-fit behaviour as `⌘9`.
- Appearance shortcut:
  - `Shift+⌘L` toggles light/dark mode.
- Toolbar commands:
  - `⌥⌘T` toggles toolbar visibility.
  - `View > Customise Toolbar…` opens native drag/drop toolbar customisation.
- In sandboxed Release builds, Quick Markdown Viewer may ask once for folder access when a document contains local relative image/link paths and macOS did not grant sibling-file scope from the initial file selection; granted folders are remembered via security-scoped bookmarks.
- Markdown rendering behaviour is designed for reading, not editing.

## Signed Release Readiness Checklist

1. In target **Signing & Capabilities**, set your Apple Developer Team for **Release** (local Xcode step).
2. Confirm Release uses:
   - App Sandbox enabled
   - Hardened Runtime enabled
   - `QuickMarkdownViewer/Resources/QuickMarkdownViewer.entitlements` (current technical path)
3. Create your local notarytool keychain profile (do not commit credentials).
4. If `README.md` changed, update the Help Book HTML copy and regenerate the Help index:
   - Update:
     - `QuickMarkdownViewer/Resources/Help/QuickMarkdownViewerHelp.help/Contents/Resources/en.lproj/index.html`
     - `QuickMarkdownViewer/Resources/Help/QuickMarkdownViewerHelp.help/Contents/Resources/index.html`
     so both copies mirror `README.md`.
   - Run:
     - `hiutil -Caf QuickMarkdownViewer/Resources/Help/QuickMarkdownViewerHelp.help/Contents/Resources/QuickMarkdownViewerHelp.helpindex QuickMarkdownViewer/Resources/Help/QuickMarkdownViewerHelp.help/Contents/Resources`
5. Run:
   - `scripts/release/make_signed_release.sh --keychain-profile QMV_NOTARY`
6. Upload the generated ZIP and SHA256 files from `dist/release` to GitHub Releases.

See [RELEASING.md](RELEASING.md) for the full maintained process.
