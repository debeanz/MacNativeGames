# Build the iPhone IPA on GitHub Actions

`.github/workflows/build-ipa.yml` runs `build_app.py --platform ios` on a GitHub-hosted Mac (macOS 26, Apple silicon,
Xcode 26), so no Mac of your own is needed. It builds from the latest `ly05010419/MacNativeGames` code, not this fork's
copy, so the fork never needs syncing.

Your game files stay on your own cloud storage. The runner downloads them with [rclone](https://rclone.org) (or from a
direct `https://` link), builds, and uploads the IPA back to your storage. Nothing from the game is stored on GitHub:
no artifacts, and the log shows file names and sizes only. This repository is public, so its logs are public too.

## What you need

- Your own **Tears of the Kingdom 1.0.0** XCI or NSP, the **1.4.3 update** NSP/NSZ (the version tested on iPhone), and
  your **prod.keys**, all from your own Switch.
- For an NSP base game: an unpacked **firmware** folder of `.nca` files, or the six shared-font `.bfttf` files.
- Cloud storage that rclone supports, with room for the game files plus a ~17 GB IPA (a free 15 GB Google Drive is
  not enough).

## One-time setup (on your PC)

1. Install rclone and add your storage as a remote. The examples below call it `drive`:

   ```
   winget install Rclone.Rclone
   rclone config
   ```

   For Google Drive, choosing the `drive.file` scope limits rclone to files it uploaded itself, which is safer for a
   token stored on GitHub. Then upload the game files with rclone:

   ```
   rclone copy D:\Switch\totk.xci drive:Switch -P
   rclone copy D:\Switch\totk-1.4.3.nsp drive:Switch -P
   ```

2. Add two repository secrets (Settings > Secrets and variables > Actions > New repository secret), or with the
   GitHub CLI in PowerShell:

   ```
   Get-Content D:\Switch\prod.keys -Raw | gh secret set PROD_KEYS -R debeanz/MacNativeGames
   Get-Content "$env:APPDATA\rclone\rclone.conf" -Raw | gh secret set RCLONE_CONF -R debeanz/MacNativeGames
   ```

   `rclone config file` shows where your `rclone.conf` is. Secrets are encrypted and hidden in logs.

## Run it

Actions tab > **Build iPhone IPA** > **Run workflow**, then fill in:

| Input | Example |
|---|---|
| game | `drive:Switch/totk.xci` |
| update | `drive:Switch/totk-1.4.3.nsp` |
| fonts | NSP base only: `drive:Switch/firmware` |
| output | `drive:Switch/ipa` |

Or from the command line:

```
gh workflow run build-ipa.yml -R debeanz/MacNativeGames -f game=drive:Switch/totk.xci -f update=drive:Switch/totk-1.4.3.nsp -f output=drive:Switch/ipa
```

Tick **dry_run** first to check, in a few minutes, that the runner has enough disk space and can see your files.

A fresh build takes one to several hours on the free runner (6-hour limit). The IPA lands in the output folder as
`TOTK-<date>-run<n>.ipa`; if the build fails, its logs go to `logs-run<n>` there.

## Install

The IPA is unsigned. Sign and install it with your sideloading tool (SideStore, AltStore, Sideloadly, ...), keeping its
entitlements: it uses the increased memory limit. It needs iOS/iPadOS 26 and an iPhone 14 or newer.
