# Changelog

All notable changes to Quick Markdown Viewer are tracked in this file from `v1.0.4` onwards.

This project loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and uses semantic versioning.

## [Unreleased]

## [1.0.5] - 2026-04-07

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
