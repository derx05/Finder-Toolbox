<div align="center">

<img src="docs/assets/app-icon.png" alt="Finder Toolbox icon" width="128" height="128" />

# Finder Toolbox

A native macOS menu bar utility that brings Finder-aware power tools to keyboard-driven users — starting with a smart, hotkey-driven file renamer.

</div>

> [!WARNING]
> **Honest disclaimer — AI involvement**
>
> This app was, in large part, built with the help of AI coding assistants. I know Swift and understand what the code is doing — what I was missing was the **time** to build this idea from scratch on my own.
>
> The app is **WIP / beta**. I use it daily, keep improving it, and will at some point do a full manual review of the codebase to make sure everything is sound — that hasn't happened yet. Use at your own discretion.

## Features

- **Hotkey-driven rename** of the current Finder selection — default `⌃⌥⌘R`, rebindable.
- **Native Finder undo** — renames go through Apple Events to Finder, so ⌘Z reverses a whole batch.
- **Smart leading-date detection** — reformats existing prefixes (`YYYY-MM-DD`, `YYYYMMDD`, `YY-MM-DD`, `YYMMDD`, `DD.MM.YYYY`, `DD.MM.YY`, with `_`/`-`/space separators) or prepends today's date.
- **Per-type date extraction** — `.eml` `Date:` header, PDF metadata + text + OCR fallback for scanned PDFs.
- **Configurable convention** — date format and filename-vs-content priority.
- **Folder rename modes** — recursive, ask, or separate two-hotkey mode.
- **Adaptive feedback** — silent for fast batches, progress window only when slow, summary dialog only when something needs attention.
- **Menu bar only**, optional Start at Login, native Automation permission flow.
- **In-app updates** via Sparkle, with Release / Beta / Development channels.

## Requirements

macOS 15.6 or later.

## Distribution

Direct distribution only — Developer ID signed and notarized. App Store is out of scope.

## Roadmap

See [`ROADMAP.md`](ROADMAP.md) on the `dev` branch for the full plan (image EXIF, filename cleanup, preview panel, recent history, folder watcher, …).
