# Changelog

All notable changes to Quick Markdown Viewer are tracked in this file from `v1.0.4` onwards.

This project loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and uses semantic versioning.

## [1.1.0] - 2026-04-21

### Added
- Native Settings window (`⌘,`) with General and Appearance panes.
- App-menu `Check for Updates…` command under `Quick Markdown Viewer`, with native result dialogs.
- Optional automatic update checking (off by default) that checks GitHub for newer releases without downloading updates automatically.
- Default Markdown viewer selector in Settings.
- Configurable `View source with` setting in `Settings > General`:
  - choose an installed editor for `File > View Source`
  - use `Select…` to choose another app from `/Applications`
  - fall back to the system default text editor if the selected app is unavailable
- Appearance preferences in Settings:
  - appearance mode (`System`, `Light`, `Dark`)
  - light/dark window background colours
  - visible background amount
  - default window size
  - toolbar size (`Small`, `Standard`, `Large`)
  - document typeface (`Sans-serif`, `Serif`)
  - document density (`Standard`, `Compact`)
  - pane-scoped reset action
- Global reset action for all Settings panes.
- Optional bundled local syntax highlighting for fenced code blocks using `highlight.js`.
- Syntax theme families:
  - GitHub
  - VS Code
  - Atom One
  - Stack Overflow
- Syntax theme preview in the Appearance pane.
- Adaptive toolbar Search item that collapses to a magnifying-glass button in narrow windows and expands in wider windows.

### Fixed
- Removed first-document open background flashing on app launch by restoring the stable v1.0.5 load transition path and resolving light/dark background colours in CSS rather than SwiftUI render-time state.
- Disabled document-only toolbar actions, such as View Source, when no document is open.

### Changed
- App version metadata:
  - `MARKETING_VERSION = 1.1.0`
  - `CURRENT_PROJECT_VERSION = 7`
  - `CFBundleShortVersionString = 1.1.0`
  - `CFBundleVersion = 7`
- `⌘E` now expands/focuses toolbar Search after successfully using selected text for Find.
- Removed `⌘J` / Jump to Selection behaviour from the app.
- Release artefact filenames now include the app version (for example, `QuickMarkdownViewer-v1.1.0-macOS.zip` and `QuickMarkdownViewer-v1.1.0-macOS-SHA256.txt`).
- Local rendering documentation now covers bundled `highlight.js` alongside `markdown-it`.
- Third-party notices now include bundled `highlight.js` and bundled syntax theme CSS files.

## [1.0.5] - 2026-04-09

### Added
- Native `File > Share` submenu with macOS share services for the active Markdown file.
- Native `Edit > Speech` submenu with `Start Speaking` and `Stop Speaking`.
- Native customisable AppKit toolbar (`NSToolbar`) with:
  - right-click display modes (`Icon and Text`, `Icon Only`, `Text Only`)
  - `View > Customise Toolbar…` drag-and-drop customisation
  - additional toolbar items (`Share`, `View Source`, `Zoom to Fit`, `Actual Size`, `Zoom Out/In`, `Print`, `Export as PDF`, `Space`, `Flexible Space`)
- `View > Hide Toolbar` / `Show Toolbar` (`⌥⌘T`).

### Changed
- App version metadata:
  - `MARKETING_VERSION = 1.0.5`
  - `CURRENT_PROJECT_VERSION = 6`
  - `CFBundleShortVersionString = 1.0.5`
  - `CFBundleVersion = 6`
- `⌘F` now adapts to toolbar state:
  - with toolbar search available, it focuses toolbar Search
  - with toolbar hidden (or Search represented as a text-only action), it opens the compact native Find panel
- Search UI wording updated to `Search` in toolbar/find controls.
- Empty-window wording updated to use macOS-standard `toolbar` terminology.
- First-document open path now prewarms WebKit, reuses the initial empty window when possible, and reveals content immediately at `WKWebView didFinish`.

### Fixed
- Improved toolbar show/hide transition behaviour by removing flash/wiggle while preserving overall window size.
- Stabilised initial `zoom-to-fit` timing to remove intermittent first-open fit spikes.

## [1.0.4] - 2026-03-30

### Added
- Initial public release of Quick Markdown Viewer.

### Changed
- App version metadata:
  - `MARKETING_VERSION = 1.0.4`
  - `CURRENT_PROJECT_VERSION = 5`
  - `CFBundleShortVersionString = 1.0.4`
  - `CFBundleVersion = 5`
