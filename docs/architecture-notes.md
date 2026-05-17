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

**Caveat to verify early in v1:** when we send Finder a batch of N renames, does it produce one undo entry for the batch or N entries? The behavior depends on how the AppleScript is structured and on Finder's internal grouping. Test with a 10-file batch as one of the first tasks. If grouping fails, options:

- (a) Wrap the whole batch in a single AppleScript `tell application "Finder" … end tell` block executed via `NSAppleScript` once, rather than N separate Apple Event messages. Often coalesces.
- (b) Accept N undo steps, document the behavior, move on.
- (c) Add a fallback "Undo last batch" menu bar action backed by our own log.

Don't pre-build (c). Ship (a), measure, decide.

---

## The future "rename API" toggle (v3)

Apple Events to Finder is slower per file than `NSFileManager`. For human-scale batches (1–100 files) it's imperceptible. For thousand-file batches it may not be.

When/if that becomes a real complaint, add a settings toggle:

- **Prefer undo** — always Apple Events to Finder. Slower, full undo.
- **Prefer speed** — always `NSFileManager`, with our own "Undo last batch" log.
- **Auto** — Apple Events for ≤ N files, `NSFileManager` above. Default N around 200.

Do **not** build this in v1 or v2. It's a real future need but it's not load-bearing for the prototype, and over-engineering it now risks bloating the rename pipeline before the basic interaction is even validated.

---

## Concurrency: `MainActor` by default

The Xcode target sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. Every type and function is `@MainActor`-isolated unless explicitly opted out. Implications:

- Don't sprinkle `@MainActor` annotations — they're redundant and noisy.
- The rename pipeline must explicitly mark the batch executor `nonisolated` (or `actor`-bound) and hop off the main thread, or batched renames will jank the menu bar / progress window.
- Apple Event scripting calls (`NSAppleScript.executeAndReturnError`) are synchronous and slow — they **must** run off the main thread.
- When updating UI from off-main code, hop back via `await MainActor.run { … }` or `Task { @MainActor in … }`.

---

## File system event source (v3 folder watcher)

When the folder-watcher feature lands, use `FSEvents` (`FSEventStreamCreate`) — not `DispatchSource.makeFileSystemObjectSource`, not directory polling. `FSEvents` is the system's intended API for "tell me when something changed in this directory tree" and is the only one that's truly energy-efficient at idle.

Polling is forbidden by the energy-efficiency constraint, period.

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
├── App/                  # @main, MenuBarExtra root, Settings scene
├── Rename/               # Pure logic: date detection, filename building
├── FinderBridge/         # Apple Events: query selection, perform rename
├── Hotkey/               # KeyboardShortcuts integration
├── UI/                   # Settings window, progress HUD, summary dialog
├── Permissions/          # Automation permission state + recovery flow
└── Assets.xcassets/
```

Tests live in a separate test target (to be added). The date-detection module is the obvious unit-test target; Apple Events code is tested manually.
