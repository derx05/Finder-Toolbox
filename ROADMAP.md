# Roadmap

Versioned feature plan for Finder Toolbox. Items in v1 are committed; later versions are intent, not contract — reorder freely as the v1 prototype reveals what actually matters.

---

## v1 — Prototype (the smallest thing that's useful daily)

**Status: shipped as 1.0.0 Beta (2026-05-18-02).** The goal was: Daniel uses this for his own filing every day. Reached.

### Project setup
- [x] Disable `ENABLE_APP_SANDBOX` (incompatible with global hotkey + Apple Events to Finder for arbitrary user files).
- [x] Keep `ENABLE_HARDENED_RUNTIME = YES`. Add `Finder Toolbox.entitlements` with `com.apple.security.automation.apple-events = YES` and an `NSAppleEventsUsageDescription` Info.plist key (via `INFOPLIST_KEY_NSAppleEventsUsageDescription`).
- [x] `INFOPLIST_KEY_LSUIElement = YES` — no Dock icon, menu bar only.
- [ ] Add a unit test target for the date-detection logic. *(Only v1 item still open. Targets: `DateDetector`, `EmlDateExtractor`.)*

### Menu bar shell
- [x] Replace `WindowGroup` with `MenuBarExtra` (template icon).
- [x] Menu items: *Settings…*, *Quit*. Recent history deferred.
- [x] Settings window opened via `Settings` scene (`SwiftUI`'s standard `Settings { … }`).

### Rename pipeline
- [x] Apple Events bridge: query Finder for current selection (returns file URLs).
- [x] Date detector: pure function, parses leading date in supported formats:
  - `YYYY-MM-DD`, `YYYYMMDD`, `YY-MM-DD`, `YYMMDD`, `DD.MM.YYYY`, `DDMMYY`
  - Tolerant of `_`, `-`, ` ` separator after the date.
  - **Only** matches at start of name; mid-filename dates are ignored.
- [x] Rename builder: produces canonical `YYYY-MM-DD Name.ext` (literal space, fixed in v1).
- [x] Rename executor: instructs Finder via Apple Events to perform the rename, so it joins Finder's undo stack. NAS-volume fallback added in #8/#10.
- [x] Conflict handling: when target exists, append ` 2`, ` 3`, … (Finder duplicate convention).

### Hotkey
- [x] Global hotkey (configurable). Default binding `⌃⌥⌘R`. Rebindable from Settings.

### Feedback
- [x] No HUD for fast/small batches.
- [x] Adaptive progress: if elapsed > ~2s and progress < ~50%, show a lightweight progress window.
- [x] End-of-batch summary dialog **only** when something needs attention (skips, conflicts, errors). Silent otherwise.
- [x] Permission denial path: if Automation permission for Finder isn't granted, surface a clear explainer with a button that deep-links to System Settings.

### Validation
- [x] Manual test: batch rename, verify ⌘Z in Finder undo behavior — observed and documented.
- [x] Manual test: rename across `.eml`, `.pdf`, `.docx`, folder, image.
- [ ] **Self-dogfooding for two weeks before committing to v2.** *(Release 2026-05-18, today 2026-05-20. Don't open v2 scope yet.)*

### Pulled forward from v2 (already shipped in 1.0.0 Beta)
- `.eml` `Date:` header extraction (`EmlDateExtractor.swift`).
- Folder-rename mode dialog with recursive / ask / two-hotkey modes (#12).
- Start at Login toggle in General settings (#5).
- Quit-existing-release-instance when launching a debug build (#7) — developer affordance, not a user feature.

---

## v2 — Smart extraction & polish

### Configurable convention
- Configurable date format string (`YYYY-MM-DD`, `YYYYMMDD`, `DD.MM.YYYY`, …).
- Configurable separator between date and name.
- Per-folder rules (a folder path → a convention override).

### Smart per-type date extraction
- ~~`.eml` / `.mbox`: parse `Date:` header from RFC 5322 source.~~ **Shipped in v1.0** — see `EmlDateExtractor.swift`. Falls back to today's date if header missing/malformed.
- PDF: read document creation date from PDF metadata via `PDFKit`.
- Images: `DateTimeOriginal` from EXIF via `ImageIO` / `CGImageSource`.
- Extraction is opt-in per file type in settings.
- Never use file-system creation/modification date as a fallback for these — explicitly disallowed by user preference (an `.eml` exported days later would get a meaningless date).

### Filename cleanup
- Trim trailing whitespace before extension.
- Strip ` (1)`, ` copy`, ` copy 2`, etc. from the original name *before* applying the date prefix.
- Normalize weird unicode (NFC), collapse double spaces.
- Opt-in toggle in settings — some users may want their filename preserved verbatim.

### UX
- Optional preview-before-commit panel (toggleable per invocation, e.g. ⇧+hotkey for preview).
- Recent history view in the menu bar dropdown — last N renames with one-click "Reveal in Finder".
- Configurable end-of-batch summary verbosity (always / on issues only / never).

---

## v3 — Watchers and automation

### Folder watcher
- Designate one or more drop folders.
- File-system events via `FSEvents` (no polling).
- Apply a per-folder rename rule on arrival.
- This is what enables the "auto-rename when an `.eml` is dragged out of Mail" workflow — the user drags into a watched folder, the toolbox handles it.

### Shortcuts integration
- Expose rename as an App Intent so it's callable from Shortcuts / automation.

### Rename API toggle
- Settings: *Prefer undo (Apple Events to Finder)* / *Prefer speed (`NSFileManager` direct, with custom undo)* / *Auto (chooses based on batch size)*.
- "Auto" threshold is configurable. Default: switch to direct `NSFileManager` above ~200 files.
- Custom undo path: maintain a rename log; menu bar action "Undo last batch" reverses it. Persisted across launches with a reasonable retention policy.

---

## v4+ — Toolbox expansion

The umbrella opens up. Concrete candidates (each gets its own concept doc before any code):

- **Quick-move** — hotkey to move selection to a frequently-used folder picked from a fuzzy-search list.
- **Batch tagging** — add/remove macOS Finder tags by hotkey.
- **Quick archive** — wrap selection into a dated `.zip` next to it.
- **Format conversion** — `.heic` → `.jpg`, etc., via system-provided converters.

Discipline rule: every new tool must preserve the headless-by-default, hotkey-first interaction model. If it requires a window to use, it doesn't belong in this toolbox.

---

## Explicitly out of scope (forever, unless reconsidered)

- App Store distribution. The interaction model requires entitlements the App Store sandbox forbids.
- Polling-based folder watching. Energy efficiency is a hard constraint.
- A general-purpose bulk-rename UI. NameChanger and A Better Finder Rename already exist; this is a different product.
- Cross-platform support. macOS-native, by design.
