# Releasing

How a new build gets to users. The app uses [Sparkle](https://sparkle-project.org)
to auto-update; GitHub Releases is the asset host. For the EdDSA
signing/key-management details (locations, backup, `sign_update`
invocation) see [`sparkle-signing.md`](sparkle-signing.md).

## Channels

The user picks one of three channels in **Settings → About → Update channel**.
The mapping is enforced in two places: `UpdateChannel` (Swift) and the
`<sparkle:channel>` element in `appcast.xml`. They must agree.

| Channel       | Tag suffix          | `<sparkle:channel>` value | Who sees it                 |
|---------------|---------------------|---------------------------|------------------------------|
| Release       | `v1.0.0`            | _(omit element)_          | everyone                     |
| Beta          | `v1.1.0-beta.1`     | `beta`                    | Beta + Development users     |
| Development   | `v1.1.0-dev.3`      | `development`             | Development users only       |

Higher channels are supersets: Beta users still receive Release updates, and
Development users receive everything. This is the standard "show me
pre-release builds" pattern — a user on Beta does not get downgraded when the
next stable Release ships.

## One-time setup

These steps happen once per machine that signs releases:

1. **Install Sparkle's tools.** After the SPM dep resolves in Xcode, the
   `Sparkle` artifact bundle ships `generate_keys`, `sign_update`, and
   `generate_appcast` under
   `~/Library/Developer/Xcode/DerivedData/.../SourcePackages/artifacts/sparkle/Sparkle/bin/`.
   Either add that path to `$PATH` or invoke them by full path.
2. **Generate the EdDSA key pair.** Run `generate_keys` once. The private key
   is stored in the macOS Keychain under the current login; the public key is
   printed to stdout. **Back up the private key** (`generate_keys -x` exports
   it) — losing it means users on older builds can never auto-update again.
3. **Wire the public key into the app.** Add the printed key as an
   `INFOPLIST_KEY_SUPublicEDKey` build setting on the target. Also add
   `INFOPLIST_KEY_SUFeedURL =
   https://raw.githubusercontent.com/derx05/Finder-Toolbox/main/appcast.xml`.
4. **Hardened runtime.** Sparkle bundles an XPC service (`Installer.xpc`)
   that is signed by the Sparkle Project, not your Team ID. With hardened
   runtime on (which this project requires for notarization), launching that
   XPC needs library validation relaxed. Add to `Finder Toolbox.entitlements`:
   ```xml
   <key>com.apple.security.cs.disable-library-validation</key>
   <true/>
   ```
   This is the standard, documented Sparkle requirement for hardened-runtime
   apps; nothing app-specific.

## Each release

1. Bump `MARKETING_VERSION` (semver) and `CURRENT_PROJECT_VERSION` (date-stamp)
   in the target's build settings. `CURRENT_PROJECT_VERSION` is what Sparkle
   compares — it must monotonically increase per channel.
2. Archive in Xcode (Product → Archive), export a Developer ID signed +
   notarized build, then zip it:
   ```sh
   ditto -c -k --sequesterRsrc --keepParent "Finder Toolbox.app" "Finder Toolbox 1.1.0-beta.1.zip"
   ```
3. Sign the zip:
   ```sh
   sign_update "Finder Toolbox 1.1.0-beta.1.zip"
   # → prints: sparkle:edSignature="…" length="…"
   ```
4. Tag the commit and push:
   ```sh
   git tag v1.1.0-beta.1
   git push origin v1.1.0-beta.1
   ```
5. Create a GitHub Release for the tag and upload the `.zip` as a release
   asset. Mark "This is a pre-release" for Beta and Development tags.
6. Add an `<item>` to `appcast.xml`, copy the values from step 3 into the
   `<enclosure>` element, set `<sparkle:channel>` per the table above (omit
   for Release), and commit + push.
7. Verify: existing installs should pick up the new build within Sparkle's
   default check interval, or immediately via **Check for Updates**.

## Tips

- `generate_appcast` can scan a folder of signed zips and emit the full
  appcast for you — useful if you maintain a local mirror of every shipped
  build.
- The first user-facing release does **not** need an appcast entry for itself
  (Sparkle in that install only learns about builds newer than the one it's
  running). The first appcast entry only matters for the _next_ update.
- Sparkle's `sparkle:version` is what gets compared; `sparkle:shortVersionString`
  is purely cosmetic. Keep `sparkle:version` aligned with `CURRENT_PROJECT_VERSION`.
