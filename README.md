# Finder Toolbox

A native macOS menu bar utility that brings Finder-aware power tools to keyboard-driven users — starting with a smart, hotkey-driven file renamer.

> **Status:** 1.0.0 Beta — Work in Progress. The app is being used daily by the author, but should still be considered beta software. Features live on the `dev` branch; `main` tracks stable public releases.

## What it does

Press a global hotkey, and whatever you have selected in Finder gets renamed according to a configured convention — with a smart date prefix detected, reformatted, or prepended. The interaction is a single keystroke; the app stays out of the way otherwise.

## Features

### Hotkey-driven renaming
- **Global hotkey** (default `⌃⌥⌘R`, fully rebindable in Settings) renames the current Finder selection in place.
- **Native Finder undo**: renames are routed through Apple Events to Finder, so a whole batch is undoable with a single ⌘Z in Finder.
- **NAS / network volume fallback** for cases where Finder's Apple Event rename fails.
- **Conflict handling** matches Finder's own duplicate convention (` 2`, ` 3`, …).

### Smart date detection
Detects and reformats a leading date prefix on each filename. Supported input formats include:
- `YYYY-MM-DD`, `YYYYMMDD`
- `YY-MM-DD`, `YYMMDD`
- `DD.MM.YYYY`, `DD.MM.YY`
- Tolerant of `_`, `-`, or space separators after the date.

Only **leading** dates are touched — dates mid-filename are left alone. If no date is found, today's date is prepended.

### Smart per-type date extraction
For files without a usable filename date, Finder Toolbox can read the *real* date from the file:
- **`.eml` files** — parses the `Date:` header from the RFC 5322 source.
- **PDFs** — PDFKit text extraction + label-aware regex (German + English), PDF metadata creation date, and a Vision OCR fallback for scanned PDFs. Configurable ask-vs-silent behavior for conflicts and missing dates.
- File-system creation/modification dates are deliberately **never** used as a fallback (an `.eml` exported days later would otherwise get a meaningless date).

### Configurable filename convention
- Configurable date format (`YYYY-MM-DD`, `YYYYMMDD`, `DD.MM.YYYY`, …).
- Configurable priority: filename-detected date vs. content-extracted date.

### Folder renaming
- Dedicated folder-rename behavior: recursive, ask-each-time, or a separate two-hotkey mode.

### Adaptive, unobtrusive feedback
- Silent for fast/small batches — no HUD, no notification.
- Adaptive progress window appears only if a batch is slow (>~2s elapsed and <~50% done).
- End-of-batch summary dialog only when something needs attention (skips, conflicts, errors). Clean runs are silent.

### Menu bar app
- Menu bar icon only — no Dock icon, no window clutter (`LSUIElement`).
- Settings live in a standard SwiftUI Settings window.
- Optional **Start at Login**.

### Permissions handled natively
- Uses the real macOS Automation permission prompt for Finder on first use.
- If permission is denied, shows a clear explainer with a button that deep-links to System Settings.

### In-app updates
- Sparkle-based auto-update fed from a GitHub-hosted appcast.
- Three selectable channels: **Release**, **Beta**, **Development**.

## Distribution

Direct distribution only — Developer ID signed and notarized. The App Store is explicitly out of scope; sandboxing is incompatible with the global-hotkey-on-Finder-selection interaction model.

## Requirements

- macOS 15.6 or later.

## Roadmap (selected)

Planned but not yet shipped:
- Image EXIF (`DateTimeOriginal`) extraction.
- Filename cleanup (`copy`, ` (1)`, double spaces, unicode normalization).
- Preview-before-commit panel.
- Recent-renames history in the menu bar dropdown.
- Per-folder rule overrides.
- Folder-watcher / drop-folder auto-rename.

See `ROADMAP.md` on the `dev` branch for the full plan.

---

## Honest disclaimer — AI involvement

This app was, in large part, built with the help of AI coding assistants.

I know Swift and I understand what the code is doing — what I was missing was the **time** to build this idea from scratch on my own. AI let me get a working tool into daily use far sooner than I otherwise could have.

What that means in practice:
- The app is currently **WIP / beta**. Treat it as such.
- I'm continuing to **use it daily**, improve it, and test it on real files.
- At some point I intend to do a **full manual review pass** over the codebase to make sure everything is sound — that hasn't happened yet.
- If you find a bug or something sketchy, please open an issue. Feedback is welcome.

Use at your own discretion until the full review is done.
