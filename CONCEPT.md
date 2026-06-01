# Finder Toolbox

> A native macOS menu bar utility that brings Finder-aware power tools to keyboard-driven users — starting with a smart, hotkey-driven file renamer.

## Overview

| Field | Details |
|---|---|
| **Type** | Native macOS app (SwiftUI), menu bar utility |
| **Stage** | 1.0.0 Beta shipped 2026-05-18. In daily self-dogfooding; iterating on planned follow-ups |
| **Team** | Solo (Daniel) |
| **Timeline** | No deadline. Iterative — ship a working prototype quickly, then grow |
| **Distribution** | Direct distribution, Developer ID signed + notarized (App Store ruled out — see below) |

**Problem**
Renaming files on macOS is tedious work that pro users do constantly: dragging an `.eml` out of Mail, downloading a PDF, dropping a screenshot — each one wants a date-prefixed, conventionally-named filename, and Finder's built-in rename UX is all manual. Worse, files often arrive *with* a date in some other format (`240315_…`, `15.03.24 …`) that needs reformatting, not just prepending. Doing this by hand 10× a day adds up.

**Solution**
A menu bar app that, on a global hotkey, takes whatever is selected in Finder and renames it according to a configured convention — detecting and reformatting any existing date prefix, or prepending today's date if none is present. The interaction is a single keystroke; the app stays out of the way otherwise.

**Target audience**
Power users on macOS who live in Finder and have an opinionated filing convention they apply repeatedly — knowledge workers who archive emails, freelancers organizing client files, anyone who keeps a date-prefixed flat folder structure. Primary user: Daniel himself; broader release is a nice-to-have, not the goal.

---

## Concept

### Vision
A small, energy-efficient toolbox of Finder-aware utilities that pro users invoke with the keyboard. The renamer is the first tool; the architecture should leave room for further tools (e.g. quick-move, batch-tagging, format conversion, archive helpers) under the same menu bar surface, without bloating the app or becoming a kitchen-sink launcher.

### Core features (released)

**Global hotkey rename**
A user-configurable global hotkey takes the current Finder selection and renames each file according to the configured convention. Single keystroke, no app to focus. Implemented via Apple Events to Finder (with the user granting Automation permission for Finder on first use — a one-time native macOS prompt).

**Smart date detection & reformatting**
For each filename, detect a date prefix at the start of the name (supported formats: `YYMMDD`, `YY-MM-DD`, `YYYYMMDD`, `YYYY-MM-DD`, `DD.MM.YYYY`, `DDMMYY`, and common variants with `_`, `-`, or space separators). If found, reformat to the canonical output. If not, prepend today's date. Dates appearing **mid-filename** are left alone — only leading dates are touched.

**Canonical output format**
`YYYY-MM-DD Name.ext` — a literal space between the date and the name. The format is configurable in Settings (multiple date formats shipped in 1.0.0 Beta); separator configurability is planned.

**Conflict resolution matching Finder**
If the target filename already exists in the destination folder, append a suffix the way Finder does for duplicates (` 2`, ` 3`, …) rather than a custom scheme — keeps the user's mental model consistent.

**Native Finder undo integration**
Because renames go through Apple Events to Finder, they land in Finder's own undo stack. A 30-file batch should be undoable as one ⌘Z in Finder (see *Architecture notes* — this is the load-bearing reason we route through Finder rather than `NSFileManager`).

**Subtle, adaptive feedback**
- Single-file or fast batches: silent and instant. No HUD, no notification.
- Adaptive progress: if the operation passes ~2 seconds and is less than ~50% complete, show a progress indicator. (Don't flash one up unnecessarily.)
- End-of-batch: a summary dialog **only** when something needs attention — skipped files, conflicts, errors. Clean runs are silent. (Planned: a verbosity setting — always / on issues only (current) / never.)

**Menu bar presence**
Menu bar icon, no Dock icon. Click reveals: Settings…, Quit, and (later) recent rename history. Designed to be unobtrusive — the user almost never interacts with it directly; the hotkey is the primary surface.

### Out of scope (for the initial release)

> Note: `.eml` `Date:` header extraction and the folder-rename mode dialog were originally listed as out-of-scope items but ended up shipping in 1.0.0 Beta. Remaining out-of-scope items below.

- PDF metadata, image EXIF extraction
- Folder watcher / drop folder auto-rename
- Filename cleanup (trailing spaces, ` (1)`, `copy`, weird unicode)
- Preview-before-commit panel
- Per-folder rules / configurable date format / configurable separator
- Auto-rename on move from Mail.app (will likely be folder-watcher–based, not Mail integration)
- Other Finder utilities under the toolbox umbrella
- Configurable rename API (Apple Events vs `NSFileManager` — see roadmap)

### Differentiators

Most existing renamers are either heavy bulk-rename apps (NameChanger, A Better Finder Rename) with multi-step UIs, or shell scripts. Finder Toolbox is differentiated by:

- **Speed of invocation** — one keystroke, zero focus changes. The interaction model is closer to "system feature" than "app."
- **Smart detection** — reformats existing date prefixes in place rather than blindly prepending, which is the exact pain point for files that already have *some* date format.
- **Native undo** — ⌘Z in Finder reverses the rename, because Finder did it. No proprietary undo stack.
- **Energy efficiency** — runs headless, idle CPU near zero. No constant background scanning unless folder-watcher is later opted in.
- **Toolbox extensibility** — architected so future Finder utilities can plug into the same menu bar surface and hotkey infrastructure.

### Competitive landscape

- **NameChanger / A Better Finder Rename** — powerful but UI-heavy; you open the app, drag files in, configure, apply. Wrong interaction model for "I just dragged this `.eml` out of Mail and want it renamed *right now*."
- **Hazel** — folder-rules engine, excellent for automation but expensive and overkill for selection-driven renames. Also folder-watcher-only; no hotkey-on-selection.
- **macOS built-in batch rename** (Finder right-click → Rename) — no smart detection, no canonical format, no global hotkey.
- **Shell scripts / Automator / Shortcuts** — work, but configuring date detection and conflict resolution by hand is friction every time.

### Constraints

- **Team**: Solo developer.
- **Budget**: Personal project; no external funding.
- **Distribution**: Direct (signed + notarized DMG). App Store sandbox is incompatible with the global-hotkey-on-Finder-selection interaction model.
- **API discipline**: Use only official, public macOS APIs. No private framework calls. Apple Events / Automation permissions are explicitly considered acceptable — they are the *intended* mechanism for this kind of cross-app integration.
- **Energy efficiency**: Idle CPU near zero. No polling loops; no constant background work. Any future folder-watching must use `FSEvents`, not directory polling.
- **Deployment target**: macOS 15.6+. Swift 5 mode, default `@MainActor` isolation.
- **Concurrency**: Code is `MainActor` by default per build settings; long-running rename batches must explicitly hop off the main thread.

### Success criteria

| Timeframe | What success looks like |
|---|---|
| **Initial release** | Daniel uses it daily for his own `.eml` / PDF filing. Hotkey works reliably. Finder undo works for batches. No regressions vs. doing it by hand. |
| **3 months** | Planned follow-ups (filename cleanup, image EXIF, separator config, summary verbosity) shipped. Stable enough that it survives a macOS point update without breaking. |
| **1 year** | At least one additional toolbox utility shipped (TBD). If quality is high, soft-published (personal site, small Show HN). Optional. |

Success is judged purely by *Daniel's own daily use*. Public release is a stretch, not a metric.

### Key risks & open questions

- **Finder undo grouping for batched renames**
  *Risk:* Apple Events instructs Finder to perform N renames; Finder may push N undo entries instead of one batch. If true, ⌘Z would only undo the last file.
  *Mitigation:* Prototyped the batch path early and verified undo behavior with a 10-file rename — wrapping the batch in a single AppleScript `tell` block makes Finder coalesce it into one undo entry. Validated in the shipped renamer; fallback options (accept N undo steps; maintain our own "Undo last batch" log) remain available if Finder's grouping behavior ever regresses.

- **Apple Events permission UX on first run**
  *Risk:* User dismisses or denies the Automation prompt for Finder, breaking the app silently.
  *Mitigation:* Detect denial, surface a clear in-app explanation with a deep link to System Settings → Privacy & Security → Automation. Don't let the app fail silently.

- **Global hotkey conflicts**
  *Risk:* Default hotkey collides with another app the user has installed.
  *Mitigation:* Hotkey is configurable from day one. Pick a default unlikely to clash (e.g. ⌃⌥⌘R) but make rebinding a first-class settings action.

- **Scope creep into "yet another bulk renamer"**
  *Risk:* Toolbox umbrella tempts feature accretion that dilutes the simple "smash one key, files renamed" interaction.
  *Mitigation:* Every new feature must answer: does this preserve the hotkey-driven, headless-by-default model? GUIs are reserved for settings and exception handling.

- **Performance vs. undo trade-off (future)**
  Apple Events to Finder is slower per file than `NSFileManager.moveItem`. For human-scale batches it's fine; for thousand-file batches it may not be. Roadmap item: a settings toggle "Prefer undo / Prefer speed / Auto" that switches rename API based on batch size.

### What shipped in 1.0.0 Beta

- Direct-distribution project config (sandbox off, hardened runtime on, entitlements + Automation usage description wired).
- Menu bar app via `MenuBarExtra`, `LSUIElement = YES`, no Dock icon. Settings window with hotkey rebinding, file-renaming options, and About page.
- Apple Events bridge to query Finder selection and perform renames (so renames land in Finder's undo stack). NAS-volume fallback path.
- Date detector for all listed leading-date formats; canonical `YYYY-MM-DD Name.ext` output; Finder-style ` 2`, ` 3` conflict suffixes.
- Global hotkey (default `⌃⌥⌘R`), rebindable in Settings.
- Adaptive progress window; end-of-batch summary dialog only on issues.
- Automation-permission denial path with a System Settings deep link.
- **Past the original scope:** `.eml` `Date:` header extraction, a folder-rename mode dialog (recursive / ask / two-hotkey), Start at Login, and a quit-existing-release-on-debug-launch developer affordance.

### Outstanding follow-ups from the initial release

1. **Unit test target** for `DateDetector` and `EmlDateExtractor` — the one checklist item still open from the initial release.
2. **Two weeks of self-dogfooding** (release was 2026-05-18). Decide what's wrong in actual daily use before greenlighting the next batch of planned features.

See `ROADMAP.md` for the released / planned / future breakdown, and `docs/architecture-notes.md` for the load-bearing technical decisions.
