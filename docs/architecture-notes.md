# Architecture notes

Load-bearing technical decisions and the reasoning behind them. If you're tempted to change one of these, read the rationale first — these are not arbitrary.

---

## Why direct distribution, not App Store

The product's defining interaction is "press a global hotkey, the app reads the current Finder selection, and renames those files." Implementing that requires:

1. A **global hotkey monitor** that fires regardless of which app is frontmost.
2. **Apple Events / Automation permission for Finder** to query the selection.
3. **Read+write access to arbitrary user files**, not just files chosen via `NSOpenPanel`.

The App Store sandbox grants (1) and (2) only in restricted forms and explicitly forbids (3) for arbitrary paths — `com.apple.security.files.user-selected.read-write` only applies to files the user picks through a system-provided picker. A renamer that requires the user to pick every file through a panel before renaming defeats the entire interaction.

Therefore: **Developer ID signed + notarized DMG, no sandbox.** Hardened Runtime stays on. The user is asked once for Automation permission for Finder; that's the price of the interaction model and is the *intended* mechanism for cross-app integration on macOS.

This is settled. Revisit only if Apple introduces a new entitlement that genuinely covers the interaction.

---

## Why Apple Events to Finder for renaming, not `NSFileManager`

Both work. The difference is **undo integration**.

- `NSFileManager.moveItem(at:to:)` performs the rename directly. Fast. But Finder has no idea it happened — there's no Finder undo entry. We'd have to build our own undo stack and figure out how a headless menu bar app surfaces ⌘Z to the user (it doesn't, cleanly).
- Apple Events `tell application "Finder" to set name of …` causes **Finder itself** to perform the rename. The operation lands in Finder's undo stack. The user presses ⌘Z in Finder — the window they're already looking at — and the rename reverses. Zero custom UX.

The user explicitly named undo as a must-have, with the observation that "how do you want the user to focus an app that runs headless?" Routing through Finder is the answer.

**Batch-undo grouping (validated in the shipped renamer):** when sending Finder a batch of N renames, we wrap the whole batch in a single AppleScript `tell application "Finder" … end tell` block executed via `NSAppleScript` once. Finder coalesces these into a single undo entry for the batch, so ⌘Z in Finder reverses the whole operation. The fallback options — accepting N undo steps, or maintaining our own "Undo last batch" log — were left unbuilt and remain available if Finder's grouping behavior ever regresses.

---

## The future "rename API" toggle

Apple Events to Finder is slower per file than `NSFileManager`. For human-scale batches (1–100 files) it's imperceptible. For thousand-file batches it may not be.

When/if that becomes a real complaint, add a settings toggle:

- **Prefer undo** — always Apple Events to Finder. Slower, full undo.
- **Prefer speed** — always `NSFileManager`, with our own "Undo last batch" log.
- **Auto** — Apple Events for ≤ N files, `NSFileManager` above. Default N around 200.

Do **not** build this preemptively. It's a real future need but it's not load-bearing today, and bloating the rename pipeline before there's an actual complaint to chase is the wrong trade.

---

## Concurrency: `MainActor` by default

The Xcode target sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. Every type and function is `@MainActor`-isolated unless explicitly opted out. Implications:

- Don't sprinkle `@MainActor` annotations — they're redundant and noisy.
- The rename pipeline must explicitly mark the batch executor `nonisolated` (or `actor`-bound) and hop off the main thread, or batched renames will jank the menu bar / progress window.
- Apple Event scripting calls (`NSAppleScript.executeAndReturnError`) are synchronous and slow — they **must** run off the main thread.
- When updating UI from off-main code, hop back via `await MainActor.run { … }` or `Task { @MainActor in … }`.

---

## File system event source (future folder watcher)

When the folder-watcher feature lands, use `FSEvents` (`FSEventStreamCreate`) — not `DispatchSource.makeFileSystemObjectSource`, not directory polling. `FSEvents` is the system's intended API for "tell me when something changed in this directory tree" and is the only one that's truly energy-efficient at idle.

Polling is forbidden by the energy-efficiency constraint, period.

---

## PDF date extraction strategy

PDFs need a layered extractor, not a single source. `PdfDateExtractor.swift` tries them in order:

1. **PDFKit text + label-aware regex (DE + EN)** — for the very common case of a date printed in the document body next to a label like *Datum / Rechnungsdatum / Date / Invoice date*. This is the highest-signal source: it matches what a human would read off the page.
2. **PDF metadata creation date** — the `/CreationDate` entry in the PDF's document info dictionary. Reliable for PDFs generated by software at the moment the document was authored; misleading for scans (date the scanner created the file, not the date on the page).
3. **Vision OCR fallback** — for scanned PDFs where PDFKit returns no usable text. Same label-aware regex run over OCR output.

What's deliberately *not* in the chain:

- **No file-system creation/modification date.** Same reasoning as `.eml`: an old document re-saved or copied yesterday would get yesterday's date, which is worse than admitting we don't know.
- **No Apple Intelligence / Foundation Models pass yet.** Scoped as a planned follow-up, gated by `#available(macOS 26.0, *)` since it requires macOS 26+.

Conflicts between sources (e.g. metadata says one date, body text says another) and missing-date cases are exposed in Settings as ask-vs-silent toggles, so the feature can run hands-off for bulk filing or interactively for one-offs. The filename-vs-content priority setting decides whether a date already present in the filename overrides what the extractor finds.

---

## In-app updates via Sparkle

The app ships outside the Mac App Store, so it owns its own update channel. We use [Sparkle](https://sparkle-project.org) with EdDSA signatures and a GitHub-hosted appcast (`appcast.xml` at the repo root). Three user-selectable channels (Release / Beta / Development) map to semver tag suffixes and `<sparkle:channel>` values — see `docs/RELEASING.md` for the per-release procedure and `docs/sparkle-signing.md` for key management.

Hardened Runtime stays on (required for notarization). Sparkle's `Installer.xpc` is signed by the Sparkle Project, not by our Team ID, so the app needs `com.apple.security.cs.disable-library-validation` in its entitlements to launch the XPC. This is the documented, supported Sparkle setup for hardened-runtime apps — not an app-specific compromise.

`UpdateController.swift` wraps `SPUStandardUpdaterController` and adds gentle update reminders so a user who dismisses the prompt isn't pestered immediately but also doesn't sit on a stale build forever.

---

## Hotkey library

Use [`KeyboardShortcuts`](https://github.com/sindresorhus/KeyboardShortcuts) (Sindre Sorhus, SPM) rather than rolling our own `NSEvent.addGlobalMonitorForEvents` plumbing. It provides:

- A native `KeyboardShortcuts.Recorder` view for the settings UI.
- Persistent storage of bindings.
- A clean callback API for the registered shortcut.
- No private APIs.

Add via Swift Package Manager. If for some reason it becomes unmaintained or insufficient, fall back to a hand-rolled `NSEvent` global monitor.

---

## Project structure (`PBXFileSystemSynchronizedRootGroup`)

The target uses `PBXFileSystemSynchronizedRootGroup`, which means **any `.swift` file added to `Finder Toolbox/` is automatically picked up by the build**. Do not edit `project.pbxproj` to register new files — that breaks the synchronization model.

Suggested in-repo Swift folder layout (just a convention, no Xcode groups needed):

```
Finder Toolbox/
├── App/                  # @main, MenuBarExtra root, Settings scene, update controller
├── Rename/               # Pure logic: date detection, filename building, PDF/EML extractors
├── FinderBridge/         # Apple Events: query selection, perform rename
├── Hotkey/               # KeyboardShortcuts integration
├── UI/                   # Progress HUD, summary dialog, conflict & folder-mode dialogs
│   └── Settings/         # Settings window pages
├── Permissions/          # Automation permission state + recovery flow
├── Support/              # Defaults keys, shared helpers
└── Assets.xcassets/
```

Tests live in the `Finder ToolboxTests` target. Pure logic modules (`DateDetector`, `EmlDateExtractor`, `PdfDateExtractor`) are covered there; Apple Events code is tested manually.
