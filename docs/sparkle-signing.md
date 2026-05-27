# Sparkle signing cheat sheet

Concrete commands for the EdDSA signing flow. This is the day-to-day
reference; for the end-to-end release procedure (versioning, tagging,
GitHub Release) see [`RELEASING.md`](RELEASING.md).

## Trust model in one sentence

The **private key** lives in this Mac's login Keychain and is used to sign
every `.zip` you ship; the **public key** is baked into the app binary via
`INFOPLIST_KEY_SUPublicEDKey` so installed copies can verify each download
came from whoever holds the private key. Lose the private key and existing
installs will reject every future update.

## Where Sparkle's tools live

After Sparkle resolves via SPM, the binaries land in DerivedData. The folder
hash is unique per machine, so look it up rather than hard-coding:

```sh
SPARKLE_BIN="$(find ~/Library/Developer/Xcode/DerivedData -path '*/artifacts/sparkle/Sparkle/bin' -type d 2>/dev/null | head -1)"
echo "$SPARKLE_BIN"
```

Use `"$SPARKLE_BIN/generate_keys"`, `"$SPARKLE_BIN/sign_update"`, etc.

If `find` returns nothing, open the project in Xcode once so SPM resolves
the artifact bundle — `bin/` only appears after a successful resolve.

## One-time: generate keys

Already done. For reference / disaster recovery:

```sh
"$SPARKLE_BIN/generate_keys"
```

- Stores the private key in the login Keychain (service
  `https://sparkle-project.org`, account `ed25519`).
- Prints the public key to stdout — that's what goes into
  `INFOPLIST_KEY_SUPublicEDKey` on the Xcode target.

### Back up the private key

```sh
"$SPARKLE_BIN/generate_keys" -x ~/sparkle_private_key.txt
# Move into 1Password (or equivalent), then:
rm ~/sparkle_private_key.txt
```

### Read the public key back (useful when rebuilding on a new machine)

```sh
security find-generic-password -s "https://sparkle-project.org" -a "ed25519" -w
```

## Each release: sign the zip

After Archive → Export → Notarize, package the `.app`:

```sh
ditto -c -k --sequesterRsrc --keepParent \
    "Finder Toolbox.app" \
    "Finder Toolbox 1.1.0-beta.1.zip"
```

Then sign it:

```sh
"$SPARKLE_BIN/sign_update" "Finder Toolbox 1.1.0-beta.1.zip"
# → sparkle:edSignature="…" length="…"
```

Copy both attributes into the `<enclosure>` element of the new
`appcast.xml` item — see `RELEASING.md` for the full appcast entry shape.

## Verifying after release

Pick a Mac that doesn't yet have the new build, open the app, **About →
Check for Updates**. If signing or the public key is wrong, Sparkle refuses
the download and logs `SUUpdaterAppcastError` / signature-verification
failures in `Console.app` (filter by process name `Finder Toolbox`).
