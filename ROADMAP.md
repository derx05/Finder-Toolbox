# Roadmap

Versioned plan for Finder Toolbox.

- **v1 — Shipped** is what's in `dev` and headed out the next beta.
- **v1.x — Near-term polish** are small, well-scoped follow-ups that fit the existing surface.
- **Future** is everything bigger — reorder freely; promote into v1.x once a concrete design exists.

---

## v1 — Shipped

The product target: a hotkey-driven smart file renamer that Daniel uses daily. Reached, then extended.

### Project shell
- Hardened Runtime, no sandbox (App Store ruled out — see `docs/architecture-notes.md`).
- Menu bar only (`LSUIElement`); Settings via SwiftUI `Settings` scene.
- Automation permission flow with deep-link recovery into System Settings.
- Start at Login toggle.
- Sparkle-based in-app updater with three channels (Release / Beta / Development) and gentle update reminders.
- Quit-existing-release-instance when launching a debug build (developer affordance).
- Unit test target covering `DateDetector`, `EmlDateExtractor`, `PdfDateExtractor`.

### Rename pipeline
- Apple Events bridge to Finder for selection + rename, so operations land in Finder's native undo stack.
- NAS-volume fallback when Apple Events to Finder fails.
- Conflict handling: append ` 2`, ` 3`, … (Finder duplicate convention).
- Folder-rename behavior selector: recursive / ask / two-hotkey.
- Configurable date format (`YYYY-MM-DD`, `YYYYMMDD`, `DD.MM.YYYY`, `YY-MM-DD`, `DD-MM-YYYY`, …).
- Configurable filename-vs-content priority for dated files (which wins when both produce a date).
- Adaptive progress window (only when a batch runs long); end-of-batch summary only when something needs attention.

### Smart date extraction
- Leading-date detection in filenames — multiple formats, separator-tolerant, start-only (mid-name dates ignored).
- `.eml` `Date:` header (RFC 5322).
- PDF: PDFKit text + label-aware regex (DE/EN) + PDF metadata creation date + Vision OCR fallback for scanned PDFs. Ask-vs-silent behavior configurable per conflict and per missing-date case.
- No file-system mtime/ctime fallback — intentional (see `docs/architecture-notes.md`).

### Hotkey
- Global hotkey, rebindable from Settings (default `⌃⌥⌘R`).

---

## v1.x — Near-term polish

Small, well-scoped follow-ups that fit the existing surface. Pick off as time permits; none of these block a release.

- **Image EXIF date extraction.** `DateTimeOriginal` via `ImageIO` / `CGImageSource`. Natural sibling to the PDF and `.eml` extractors.
- **Configurable separator** between date and name (currently fixed to a literal space).
- **Filename cleanup pass.** Trim trailing whitespace before extension; strip ` (1)`, ` copy`, ` copy 2`; NFC-normalize; collapse double spaces. Opt-in — some users want the filename preserved verbatim.
- **Summary verbosity setting.** Always / on issues only (current) / never.
- **Apple Intelligence fallback for PDF dates** when nothing else hits — gated by `#available(macOS 26.0, *)`. Already scoped in `PdfDateExtractor`.

---

## Future

Bigger shape changes. Each gets a real design pass before code. Reorder as priorities reveal themselves.

### Smart rename surface
- **Preview-before-commit panel** — toggleable per invocation (e.g. ⇧+hotkey for preview).
- **Recent history in the menu bar dropdown** — last N renames with one-click "Reveal in Finder".
- **Per-folder rules** — a folder path overrides the global convention (date format, separator, extraction priority).

### Watchers & automation
- **Folder watcher** via `FSEvents` (energy-efficient, no polling). Per-folder rules apply on arrival. Enables the "drag an `.eml` out of Mail into a watched folder, get it auto-renamed" workflow.
- **Shortcuts integration** — expose rename as an App Intent so it's callable from Shortcuts / automations.
- **Rename API toggle.** *Prefer undo (Apple Events)* / *Prefer speed (`NSFileManager` + custom undo log)* / *Auto* (threshold-based, default ~200 files). Persistent undo log across launches with a retention policy.

### Toolbox expansion
The umbrella opens up. Concrete candidates, each needing its own concept doc:
- **Quick-move** — hotkey + fuzzy folder picker for the current selection.
- **Batch tagging** — add/remove macOS Finder tags by hotkey.
- **Quick archive** — wrap selection into a dated `.zip` next to it.
- **Format conversion** — `.heic` → `.jpg`, etc., via system-provided converters.

Discipline rule: every new tool preserves headless-by-default, hotkey-first interaction. If it requires a window to use, it doesn't belong in this product.

---

## Explicitly out of scope

- **App Store distribution.** The interaction model needs entitlements the sandbox forbids.
- **Polling-based folder watching.** Energy efficiency is a hard constraint.
- **A general-purpose bulk-rename UI.** NameChanger and A Better Finder Rename already exist; this is a different product.
- **Cross-platform support.** macOS-native, by design.
- **File-system creation/modification date as a fallback for smart extraction.** An `.eml` exported days after receipt would otherwise get a meaningless date.
