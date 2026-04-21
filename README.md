# Quick Markdown Viewer

Quick Markdown Viewer is a native Markdown viewer for opening Markdown files as clean, rendered documents on macOS.

It is designed to feel like using Mac's Preview app for viewing Markdown documents, without editing tools or setup.

Quick Markdown Viewer is free and open-source. If you find it useful, [optional contributions are greatly appreciated](https://ko-fi.com/naohideyamamoto) and help cover ongoing maintenance costs. Contributions are voluntary and do not change Quick Markdown Viewer’s functionality.


[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/naohideyamamoto)

For developer and release details, see [README.developers.md](README.developers.md).

## Contents

- [What Quick Markdown Viewer Is For](#what-quick-markdown-viewer-is-for)
- [System Requirements](#system-requirements)
- [Quick Start](#quick-start)
- [Supported File Types](#supported-file-types)
- [Markdown Compatibility](#markdown-compatibility)
- [Set as the Default App](#set-as-the-default-app)
- [Full Functionality](#full-functionality)
- [Keyboard Shortcuts](#keyboard-shortcuts)
- [Licence](#licence)
- [Official Builds and Forks](#official-builds-and-forks)
- [No Warranty](#no-warranty)
- [Known Issues](#known-issues)
- [Troubleshooting](#troubleshooting)
- [What Quick Markdown Viewer Is Not For](#what-quick-markdown-viewer-is-not-for)
- [Support](#support)

## What Quick Markdown Viewer Is For

- Quickly opening Markdown files with proper headings, lists, tables, images, and other common Markdown features.
- Reading Markdown locally on your Mac without uploading documents to a remote rendering service.
- A native 'Preview for Markdown' workflow on Mac.

## System Requirements

- macOS 13 or newer.
- Apple Silicon Mac is the primary target.

## Quick Start

1. Go to this repository's **Releases** page.
2. Download the latest app ZIP (`QuickMarkdownViewer-v<version>-macOS.zip`).
3. Open the ZIP and drag `Quick Markdown Viewer.app` into `Applications`.
4. Open the app once.
5. Open a Markdown file by either:
   - double-clicking a supported Markdown file associated with Quick Markdown Viewer
   - right-clicking a Markdown file and choosing **Open With > Quick Markdown Viewer**
   - opening the app and pressing `⌘O`

## Supported File Types

Quick Markdown Viewer accepts:
- `.md`
- `.markdown`
- `.mdown`
- `.mkd`
- `.mkdn`
- `.mdwn`

If you select Quick Markdown Viewer as the default Markdown viewer in Settings (`⌘,`), macOS applies that choice to its grouped Markdown types (currently `.md` and `.markdown`).

Quick Markdown Viewer intentionally does not support:
- `.rmd`
- `.qmd`

## Markdown Compatibility

Quick Markdown Viewer is intended for standard Markdown document rendering. It is not designed to reproduce non-standard or modified Markdown formats. For example, the links to section headings used in the table of contents above, which are supported by GitHub's Markdown processor, do not work on Quick Markdown Viewer.

## Set as the Default App

You can set Quick Markdown Viewer as the default Markdown viewer from Settings:

1. Open Quick Markdown Viewer.
2. Open Settings (`⌘,`).
3. In the General pane, choose **Quick Markdown Viewer** as the default Markdown viewer.

You can also use Finder:

1. Select a Markdown file in Finder and press `⌘I`.
2. In **Open with**, choose **Quick Markdown Viewer**.
3. Click **Change All…**.

## Full Functionality

- Read-only Markdown viewing (no editing surface).
- One document per window.
- Native customisable macOS toolbar with persisted layout/display mode.
- Native Settings window (`⌘,`) with General and Appearance panes:
  - General: default Markdown viewer, View Source app, update checking, and reset actions
  - Appearance: appearance mode, background colours, visible background amount, default window size, toolbar size, document style, syntax highlighting, and reset actions
- Document style controls in Settings:
  - Typeface: `Sans-serif` or `Serif`
  - Density: `Standard` or `Compact`
- File open from:
  - double-click in Finder (when associated)
  - `File > Open` (`⌘O`)
  - drag and drop
  - `File > Open Recent`
- Native file sharing:
  - `File > Share` submenu
  - toolbar `Share` button
- External links open in your default browser or mail app.
- Local Markdown links open in a new Quick Markdown Viewer window.
- Relative local images are rendered from the document folder.
- Syntax highlighting in Settings (for fenced code blocks only; off by default).
  - On-screen code uses the selected theme.
  - Print and PDF export always use that theme’s light-mode colours.
- In-document search:
  - `⌘F` find
  - `⌘G` next
  - `Shift+⌘G` previous
  - `⌘E` use selection for find
  - case-insensitive and case-sensitive modes
- Adaptive toolbar Search:
  - expands to a normal search field in wide windows
  - collapses to a magnifying-glass button in narrow windows
- With the toolbar hidden, `⌘F` opens a compact native find panel with the same query/mode state as toolbar search.
- Zoom controls:
  - zoom in/out
  - actual size (100%)
  - zoom to fit
- `View > Hide Toolbar` / `Show Toolbar` (`⌥⌘T`) and `View > Customise Toolbar…`.
- Toolbar customisation supports drag/drop rearrangement, `Space`, and `Flexible Space`.
- Light/dark mode toggle.
- Print rendered Markdown (`⌘P`).
- Export rendered Markdown as PDF.
- Native speech controls under `Edit > Speech` (`Start Speaking` / `Stop Speaking`).
- View raw source in the app selected in `Settings > General > View source with`.
  - If the selected app becomes unavailable, Quick Markdown Viewer falls back to the system default text editor.
- `Check for Updates…` in the app menu, with optional automatic checking.
  - Automatic checking is off by default.
  - When enabled, Quick Markdown Viewer contacts GitHub only to check whether a newer version is available.

## Keyboard Shortcuts

- `⌘O`: open file
- `⌘,`: open Settings
- `⌘F`: find in document
- `⌘G`: find next
- `Shift+⌘G`: find previous
- `⌘E`: use selection for find
- `⌘P`: print
- `⌘=`: zoom in
- `⌘-`: zoom out
- `⌘0`: actual size (100%)
- `⌘9`: zoom to fit
- `⌥⌘T`: hide/show toolbar
- `Shift+⌘L`: toggle light/dark mode

## Licence

Quick Markdown Viewer source code is licensed under the Apache License, Version 2.0.

See [LICENSE](LICENSE) for the full licence text, [NOTICE](NOTICE) for project attribution, and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for bundled third-party notices.

The Quick Markdown Viewer name, app icon, and related branding are not licensed under Apache-2.0. See [TRADEMARKS.md](TRADEMARKS.md).

## Official Builds and Forks

Quick Markdown Viewer is open-source software. You are welcome to read the code, build it, fork it, and modify it under the terms of the Apache License, Version 2.0.

Official public builds are only those released by Naohide Yamamoto through this repository's Releases page and signed/notarised by Naohide Yamamoto.

If you obtain Quick Markdown Viewer from another source, or from a fork, treat that build as unofficial unless it is clearly identified as an official release from this repository and carries the expected signing/notarisation status.

If you redistribute a modified build, please rename the app and replace the icon and related branding unless you have explicit permission to use the official Quick Markdown Viewer branding.

## No Warranty

Quick Markdown Viewer is provided under the Apache License, Version 2.0 on an 'AS IS' basis, without warranties or conditions of any kind.

You are responsible for reviewing, building, and using the software at your own risk.

## Known Issues

- Native macOS Help Viewer integration currently fails on some systems with the message 'The selected content is currently unavailable', even when Help-book registration calls report success.
- Current practical behaviour: `Help > Quick Markdown Viewer Help` opens bundled in-app Help content directly instead of relying on Help Viewer page loading.
- Native toolbar customisation has deferred behaviour gaps:
  - Right-clicking an existing toolbar item may not show `Remove Item`, even though `View > Customise Toolbar…` still supports removing items.
  - `Flexible Space` may not visibly resize with window width changes in some toolbar layouts. This behaviour is also seen in Apple's Preview on the same macOS version and is currently treated as system-level/AppKit style interaction.
- On some macOS builds, the app menu `Settings…` item may still display the generic gear icon even when Quick Markdown Viewer requests `gearshape`.
- Default-app association UI may not live-refresh across open windows. For example, changing the Markdown default app in Quick Markdown Viewer Settings may not immediately update an already-open Finder `Get Info` panel, and changing it in Finder may not immediately update an already-open Quick Markdown Viewer Settings pane.

## Troubleshooting

- File does not open: confirm the file extension is supported.
- Image is missing: check that the image path is correct relative to the Markdown file location.
- `.md` opens in another app: set Quick Markdown Viewer as default via `Settings…` or Finder (**Open with > Change All…**).
- Window opens too large or goes beyond the screen: open Settings (`⌘,`) and reduce the default window size in the Appearance pane.

## What Quick Markdown Viewer Is Not For

Quick Markdown Viewer is not:
- a Markdown editor
- a note-taking app
- a live-preview writing environment
- a knowledge base or file-browser workspace
- an IDE-style tool

There are no multi-document panes, plugins, cloud sync, collaborative features, or advanced authoring workflows.

## Support

For bug reports, feature requests, and general help, please use this repository's GitHub Issues page.

For other project-related enquiries, please email [hello@quickmarkdownviewer.app](mailto:hello@quickmarkdownviewer.app).

Support is provided on a best-effort basis.
