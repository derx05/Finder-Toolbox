# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

**Finder Toolbox** — a native macOS menu bar utility that brings Finder-aware power tools to keyboard-driven users. Bundle ID `danielammann.Finder-Toolbox`, category `utilities`. Solo project, no deadline.

The first feature is a **hotkey-driven smart file renamer**: press a global hotkey, the app queries Finder for the current selection, detects/reformats any leading date prefix (or prepends today's date), and renames via Apple Events to Finder so it lands in Finder's native undo stack. The "toolbox" name reserves room for further Finder utilities under the same menu bar surface.

For the full product context, read in this order:
1. **`CONCEPT.md`** — what this is, who it's for, why these design choices.
2. **`ROADMAP.md`** — released / planned / future features. No fixed version slots; features ship when ready.
3. **`docs/architecture-notes.md`** — load-bearing technical decisions and their rationale (App Store rejection, Apple Events vs `NSFileManager`, hotkey library, FSEvents, etc.). Read this before touching the rename pipeline.

1.0.0 Beta is shipped. Source lives under `Finder Toolbox/` in feature-named folders (`App/`, `Rename/`, `FinderBridge/`, `Hotkey/`, `UI/`, `UI/Settings/`, `Permissions/`, `Support/`). The renamer is end-to-end functional, including `.eml` `Date:` header extraction (originally planned for later) and a folder-rename mode dialog (recursive / ask / two-hotkey). Local builds and archives live in `builds/` (gitignored).

## Build / Run

There is no test target and no SPM package — just the Xcode project. (A test target for `DateDetector` / `EmlDateExtractor` is still outstanding — see `ROADMAP.md`.) Use `xcodebuild` from the repo root (note the spaces in the project path):

```sh
# Build (Debug)
xcodebuild -project "Finder Toolbox.xcodeproj" -scheme "Finder Toolbox" -configuration Debug build

# Clean
xcodebuild -project "Finder Toolbox.xcodeproj" -scheme "Finder Toolbox" clean

# Run the built app
open "$(xcodebuild -project 'Finder Toolbox.xcodeproj' -scheme 'Finder Toolbox' -showBuildSettings 2>/dev/null | awk -F= '/ BUILT_PRODUCTS_DIR /{gsub(/ /,"",$1); print $2}' | tr -d ' ')/Finder Toolbox.app"
```

Most day-to-day iteration is expected to happen in Xcode (⌘R / ⌘B / SwiftUI Previews).

## Project structure conventions

- The target uses `PBXFileSystemSynchronizedRootGroup` — **new `.swift` files dropped into `Finder Toolbox/` are picked up automatically**. Do not hand-edit `project.pbxproj` to register new files.
- Folder layout inside `Finder Toolbox/`: `App/`, `Rename/`, `FinderBridge/`, `Hotkey/`, `UI/` (with `UI/Settings/`), `Permissions/`, `Support/`. See `docs/architecture-notes.md` for rationale. These are filesystem folders, not Xcode groups.
- Asset catalog lives at `Finder Toolbox/Assets.xcassets/` (uses `AppIcon` and `AccentColor`). Swift symbols for assets are generated (`ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES`).
- Localization prefers String Catalogs (`LOCALIZATION_PREFERS_STRING_CATALOGS = YES`, `STRING_CATALOG_GENERATE_SYMBOLS = YES`) — add a `.xcstrings` file rather than `.strings` if you need localization.
- Info.plist is generated (`GENERATE_INFOPLIST_FILE = YES`); add Info.plist keys via `INFOPLIST_KEY_*` build settings, not by creating an Info.plist file. The menu-bar-only behavior is set via `INFOPLIST_KEY_LSUIElement = YES`, and the Automation usage string via `INFOPLIST_KEY_NSAppleEventsUsageDescription` — both already wired.

## Concurrency model

The target sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and `SWIFT_APPROACHABLE_CONCURRENCY = YES`. New code is `@MainActor`-isolated by default — explicitly mark types/functions `nonisolated` (or move them onto another actor) when they should run off the main thread. Don't sprinkle `@MainActor` onto every type; it's redundant here.

In particular, the rename batch executor and any `NSAppleScript.executeAndReturnError` call **must** run off the main thread to avoid janking the menu bar / progress UI. Hop back via `await MainActor.run { … }` or `Task { @MainActor in … }` for UI updates.

Swift language mode is 5.0 with upcoming feature `MEMBER_IMPORT_VISIBILITY` enabled.

## Sandbox & entitlements

Current settings (as shipped in 1.0.0 Beta):

- `ENABLE_APP_SANDBOX = NO` — sandbox is off. Required for the global-hotkey-on-Finder-selection interaction model. App Store distribution is explicitly out of scope; see `docs/architecture-notes.md` for the full rationale.
- `ENABLE_HARDENED_RUNTIME = YES` — required for Developer ID notarization.
- `ENABLE_USER_SCRIPT_SANDBOXING = YES` — fine; this is for build phase scripts, unrelated to runtime sandboxing.
- `Finder Toolbox.entitlements` is wired via `CODE_SIGN_ENTITLEMENTS` and contains `com.apple.security.automation.apple-events`.
- `INFOPLIST_KEY_NSAppleEventsUsageDescription` is set (the user-facing string macOS shows when prompting for Automation permission for Finder).
- `INFOPLIST_KEY_LSUIElement = YES` — menu bar accessory only, no Dock icon.

## Distribution

**Direct distribution only.** Developer ID signed + notarized DMG. App Store ruled out — see `docs/architecture-notes.md` for the rationale (don't relitigate this without reading it first).

**GitHub release descriptions must end with a "Full changelog" link** comparing this release to the previous release on the **same channel**:

- dev → previous dev tag (e.g. `v0.2.0-dev.2...v0.2.0-dev.3`)
- beta → previous beta tag (e.g. `v0.1.0-beta.2...v0.1.0-beta.3`)
- release → previous stable release tag (skip dev/beta tags entirely)

Format: `**Full changelog**: https://github.com/derx05/Finder-Toolbox/compare/<prev-tag>...<this-tag>`. The release-naming and tagging conventions in `docs/RELEASING.md` are already correct — only the description body needs this addition.

## Deployment targets

- App target: macOS **15.6** (`MACOSX_DEPLOYMENT_TARGET = 15.6` at the target level).
- Project-level setting is `26.4`, but the target overrides it — 15.6 is the effective floor. Keep API usage within macOS 15 unless you intentionally raise the target.

## Versioning

`MARKETING_VERSION = "1.0.0 Beta"`, `CURRENT_PROJECT_VERSION` uses a date-stamp scheme (currently `2026-05-18-02`). Bump the date-stamp on each build you intend to ship.

## Hard constraints (do not violate without discussion)

- **Official public APIs only.** No private framework calls.
- **Energy-efficient at idle.** No polling. Folder watching uses `FSEvents`. The app is headless when not actively performing a rename.
- **Headless-by-default interaction.** The hotkey is the primary surface. GUIs are reserved for settings and exception handling. New "toolbox" features must preserve this — if a feature requires a window to use, it doesn't belong in this product.
- **Smart-extraction date sources are explicit.** `.eml` Date header, PDF metadata, image EXIF — never file-system creation/modification dates as a fallback for these (an `.eml` exported days after receipt would otherwise get a meaningless date).
