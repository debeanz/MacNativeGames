# Build the iPhone IPA on GitHub Actions

`.github/workflows/build-ipa.yml` runs `build_app.py --platform ios` on a GitHub-hosted Mac (macOS 26, Apple silicon,
Xcode 26), so no Mac of your own is needed. It builds from the latest `ly05010419/MacNativeGames` code, not this fork's
copy, so the fork never needs syncing.

`.github/pc/build-ipa.ps1` does the rest from a Windows PC:

1. It encrypts your game files with a password of your own (AES-256) and uploads them in 2000 MB pieces to a **draft**
   release of this fork. Only accounts with write access to the repository can see a draft release, and without the
   password the pieces are unreadable.
2. It starts the workflow. The PC can be switched off while the run builds (one to several hours; free macOS runners
   can also wait a while in the queue first).
3. It downloads the IPA, which the run leaves as an encrypted artifact, decrypts it, checks its SHA-256, and deletes the
   game files and the artifact from GitHub.

The password is made on first use and kept in `%LOCALAPPDATA%\TOTK-IPA\password.txt` and in the `FILE_PASS` secret.
This repository is public, so its run logs are too; they show file names and sizes, never the files or the keys.

## What you need

- Your own **Tears of the Kingdom 1.0.0** XCI or NSP, the **1.4.3 update** NSP/NSZ (the version tested on iPhone), and
  your **prod.keys**, all from your own Switch.
- For an NSP base game: an unpacked **firmware** folder of `.nca` files, or the six shared-font `.bfttf` files.
- The GitHub CLI, signed in: `winget install GitHub.cli`, then `gh auth login`.
- Free disk space for about twice the IPA (~35 GB) when it comes back: the encrypted download and the decrypted IPA.

## Build

In PowerShell, in the folder that holds `build-ipa.ps1`:

```
powershell -ExecutionPolicy Bypass -File build-ipa.ps1 -Game D:\Switch\totk.xci -Update D:\Switch\totk-1.4.3.nsp -Keys D:\Switch\prod.keys
```

For an NSP base game add `-Fonts D:\Switch\firmware`. `-Keys` stores your prod.keys as the encrypted `PROD_KEYS`
secret; later runs can leave it out. If the upload stops, run the same command again: pieces already uploaded are
skipped.

Leave the window open and the IPA lands in your Downloads folder when the run is done. Or close it, and afterwards:

```
powershell -ExecutionPolicy Bypass -File build-ipa.ps1 -Receive
```

`-OutDir <folder>` puts the IPA somewhere else; `-KeepInputs` keeps the uploaded game files for another build. If a
build fails, its logs are in an encrypted artifact of the run, and the game files stay uploaded for the next try.

`-Test` instead checks the whole path in a few minutes without building: the game files go up and are decrypted and
checked on the runner, and a 200 MB stand-in for the IPA comes back.

## Other sources

The workflow's `game`, `update`, `fonts` and `output` inputs also take [rclone](https://rclone.org) paths (with the
remote's config in the `RCLONE_CONF` secret) or direct `https://` links, for game files on your own cloud storage.

## Install

The IPA is unsigned. Sign and install it with your sideloading tool (SideStore, AltStore, Sideloadly, ...), keeping its
entitlements: it uses the increased memory limit. It needs iOS/iPadOS 26 and an iPhone 14 or newer.
