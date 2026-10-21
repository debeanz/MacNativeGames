# Build the iPhone IPA on GitHub Actions

`.github/workflows/build-ipa.yml` runs `build_app.py --platform ios` on a GitHub-hosted Mac (macOS 26, Apple silicon,
Xcode 26), so no Mac of your own is needed. It builds from the latest `ly05010419/MacNativeGames` code, not this fork's
copy, so the fork never needs syncing.

The runner downloads your game files with [rclone](https://rclone.org), builds, and sends the IPA back. Nothing from the
game is stored on GitHub: no artifacts, and the log shows file names and sizes only. This repository is public, so its
logs are public too. The files can come from:

- **your PC** (free, no cloud account): see [Build straight from your PC](#build-straight-from-your-pc);
- **cloud storage** rclone supports, with room for the game files plus a ~17 GB IPA: see [Build from cloud storage](#build-from-cloud-storage);
- a direct `https://` link.

## What you need

- Your own **Tears of the Kingdom 1.0.0** XCI or NSP, the **1.4.3 update** NSP/NSZ (the version tested on iPhone), and
  your **prod.keys**, all from your own Switch.
- For an NSP base game: an unpacked **firmware** folder of `.nca` files, or the six shared-font `.bfttf` files.

## Build straight from your PC

`.github/pc/build-from-pc.ps1` shares the game file's folder through a temporary, password-protected Cloudflare quick
tunnel (no Cloudflare account) and starts the workflow; when the IPA is built, the runner opens a tunnel of its own and the script downloads the IPA through it and checks it. Your
PC must stay on and online until it says the IPA is ready; it keeps Windows from sleeping meanwhile. The runner pulls
16-20 GB at your upload speed (about 2 hours at 20 Mbit/s); the ~17 GB IPA comes back at your download speed.

1. Once: install the tools and sign in to GitHub.

   ```
   winget install Rclone.Rclone
   winget install Cloudflare.cloudflared
   winget install GitHub.cli
   gh auth login
   ```

2. Put the update (and for an NSP, the firmware folder) in the game file's folder or a folder inside it.

3. Optional: check the tunnel both ways in a few minutes (200 MB each way, speeds in the run summary):

   ```
   powershell -ExecutionPolicy Bypass -File .github\pc\build-from-pc.ps1 -Game D:\Switch\totk.xci -Test
   ```

4. Build. `-Keys` stores your prod.keys as the encrypted `PROD_KEYS` secret (needed once):

   ```
   powershell -ExecutionPolicy Bypass -File .github\pc\build-from-pc.ps1 -Game D:\Switch\totk.xci -Update D:\Switch\totk-1.4.3.nsp -Keys D:\Switch\prod.keys
   ```

   For an NSP base game add `-Fonts D:\Switch\firmware`. The IPA appears next to the game file as
   `TOTK-<date>-run<n>.ipa`; if the build fails, its logs are in `from-runner\logs-run<n>` there.

## Build from cloud storage

1. Install rclone and add your storage as a remote. The examples below call it `drive`:

   ```
   winget install Rclone.Rclone
   rclone config
   ```

   For Google Drive, the `drive.file` scope limits rclone to files it uploaded itself, which is safer for a token
   stored on GitHub (`rclone config create drive drive scope=drive.file`). Then upload the game files with rclone:

   ```
   rclone copy D:\Switch\totk.xci drive:Switch -P
   rclone copy D:\Switch\totk-1.4.3.nsp drive:Switch -P
   ```

2. Add two repository secrets (Settings > Secrets and variables > Actions > New repository secret), or with the
   GitHub CLI in PowerShell:

   ```
   gh secret set PROD_KEYS -R debeanz/MacNativeGames --body (Get-Content D:\Switch\prod.keys -Raw)
   gh secret set RCLONE_CONF -R debeanz/MacNativeGames --body (Get-Content (rclone config file | Select-Object -Last 1) -Raw)
   ```

3. Actions tab > **Build iPhone IPA** > **Run workflow**, then fill in:

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

   The **check** mode shows in a few minutes whether the runner has enough disk space and can see your files. The IPA
   lands in the output folder as `TOTK-<date>-run<n>.ipa`; if the build fails, its logs go to `logs-run<n>` there.

A fresh build takes one to several hours on the free runner (6-hour limit), and free macOS runners can wait a while in
the queue first.

## Install

The IPA is unsigned. Sign and install it with your sideloading tool (SideStore, AltStore, Sideloadly, ...), keeping its
entitlements: it uses the increased memory limit. It needs iOS/iPadOS 26 and an iPhone 14 or newer.
