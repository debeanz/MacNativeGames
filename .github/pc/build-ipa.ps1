<#
.SYNOPSIS
Builds the Tears of the Kingdom IPA on GitHub Actions from the game files on this PC, and brings the IPA back.

.DESCRIPTION
1. Encrypts the game files with your own password (AES-256, the same format as "openssl enc -aes-256-cbc -pbkdf2") and
   uploads them in 2000 MB pieces to the draft release "totk-input" on your fork. Only accounts with write access to the
   repository see a draft release, and without the password the pieces are noise. Pieces already uploaded are skipped,
   so an interrupted upload continues where it stopped.
2. Starts the "Build iPhone IPA" workflow. The PC can be switched off while it runs (one to several hours).
3. Downloads the encrypted IPA the run leaves, decrypts it next to the game file, checks its SHA-256, and deletes it
   from GitHub. If the window was closed, run the script again with -Receive.

The password is made on first use, kept in %LOCALAPPDATA%\TOTK-IPA\password.txt and stored as the FILE_PASS secret.
Needs the GitHub CLI, signed in (winget install GitHub.cli, then gh auth login).

.EXAMPLE
.\build-ipa.ps1 -Game D:\Switch\totk.xci -Update D:\Switch\totk-1.4.3.nsp -Keys D:\Switch\prod.keys
Uploads, builds and, if the window stays open, downloads the IPA.

.EXAMPLE
.\build-ipa.ps1 -Receive
Downloads and decrypts the newest IPA (into -OutDir, by default the Downloads folder).
#>
param(
    [string] $Game,
    [string] $Update,
    [string] $Fonts,
    [string] $Keys,
    [switch] $Receive,
    [switch] $Test,
    [switch] $KeepInputs,
    [string] $OutDir,
    [string] $Repo = 'debeanz/MacNativeGames',
    [ValidateSet('macos-26', 'macos-26-xlarge')] [string] $Runner = 'macos-26'
)
$ErrorActionPreference = 'Stop'
$Release = 'totk-input'
$Iter = 100000            # PBKDF2 rounds, as ITER in the workflow
$PieceSize = 2000MB       # GitHub takes release files up to 2 GiB

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'gh not found: winget install GitHub.cli, then gh auth login' }
# gh's JSON as objects, an array's items one by one; Out-String first, since Windows PowerShell's ConvertFrom-Json takes a
# piped document line by line and passes an array on whole
function GhJson { (& gh @args | Out-String) | ConvertFrom-Json | ForEach-Object { $_ } }
# A native command with its output discarded; Windows PowerShell turns redirected stderr into errors that 'Stop' throws
function Quiet { $ErrorActionPreference = 'Continue'; $exe, $rest = $args; & $exe @rest *> $null }

# ---- the password ----
$store = Join-Path $env:LOCALAPPDATA 'TOTK-IPA'
$passFile = Join-Path $store 'password.txt'
if (Test-Path -LiteralPath $passFile) {
    $pass = (Get-Content -LiteralPath $passFile -Raw).Trim()
} elseif ($Receive) {
    throw "no password in ${passFile}: the IPA can only be decrypted on the PC that uploaded the game files"
} else {
    New-Item -ItemType Directory -Force -Path $store | Out-Null
    $bytes = New-Object byte[] 30
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $pass = [Convert]::ToBase64String($bytes).Replace('+', 'A').Replace('/', 'B')
    [IO.File]::WriteAllText($passFile, $pass)
    Write-Host "new password saved in $passFile (keep it to decrypt the IPA)"
}

# ---- AES-256-CBC with a PBKDF2-SHA256 key, laid out as openssl enc writes it: "Salted__", salt, ciphertext ----
function New-Aes([byte[]] $salt) {
    $kdf = [Security.Cryptography.Rfc2898DeriveBytes]::new([Text.Encoding]::UTF8.GetBytes($pass), $salt, $Iter,
        [Security.Cryptography.HashAlgorithmName]::SHA256)
    [byte[]] $material = $kdf.GetBytes(48)
    $kdf.Dispose()
    $aes = [Security.Cryptography.Aes]::Create()
    $aes.Mode = 'CBC'; $aes.Padding = 'PKCS7'
    $aes.Key = $material[0..31]; $aes.IV = $material[32..47]
    $aes
}

# Encrypts the next $count bytes of $source into $path, adding them to the running hash $sha
function Protect-Piece([IO.Stream] $source, [long] $count, [string] $path, $sha) {
    $salt = New-Object byte[] 8
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($salt)
    $aes = New-Aes $salt
    $out = [IO.File]::Create($path)
    try {
        $out.Write([Text.Encoding]::ASCII.GetBytes('Salted__'), 0, 8)
        $out.Write($salt, 0, 8)
        $crypto = New-Object Security.Cryptography.CryptoStream $out, $aes.CreateEncryptor(), ([Security.Cryptography.CryptoStreamMode]::Write)
        Copy-Bytes $source $count $sha $crypto
        $crypto.FlushFinalBlock()
        $crypto.Dispose()
    } finally { $out.Dispose(); $aes.Dispose() }
}

# Copies (or, without $target, only reads) the next $count bytes of $source, adding them to the running hash $sha
function Copy-Bytes([IO.Stream] $source, [long] $count, $sha, [IO.Stream] $target) {
    $buffer = New-Object byte[] (8MB)
    while ($count -gt 0) {
        $n = $source.Read($buffer, 0, [int][Math]::Min($buffer.Length, $count))
        if ($n -le 0) { throw 'the file ended early' }
        [void] $sha.TransformBlock($buffer, 0, $n, $null, 0)
        if ($target) { $target.Write($buffer, 0, $n) }
        $count -= $n
    }
}

# A downloaded artifact: the file as uploaded, or the one file inside it when it came as a zip. Returns the stream to
# read and the object to dispose afterwards.
function Open-Artifact([string] $path) {
    $file = [IO.File]::OpenRead($path)
    $magic = New-Object byte[] 2
    $n = $file.Read($magic, 0, 2); $file.Position = 0
    if ($n -eq 2 -and $magic[0] -eq 0x50 -and $magic[1] -eq 0x4B) {   # "PK"
        Add-Type -AssemblyName System.IO.Compression
        $zip = New-Object IO.Compression.ZipArchive $file, ([IO.Compression.ZipArchiveMode]::Read)
        return @($zip.Entries[0].Open(), $zip)
    }
    @($file, $file)
}

function Unprotect-File([string] $path, [string] $target) {
    $in, $owner = Open-Artifact $path
    try {
        $header = New-Object byte[] 16
        $n = 0
        while ($n -lt 16) { $r = $in.Read($header, $n, 16 - $n); if ($r -le 0) { break }; $n += $r }
        if ($n -ne 16 -or [Text.Encoding]::ASCII.GetString($header, 0, 8) -ne 'Salted__') {
            throw "$path is not an encrypted file from the workflow"
        }
        $aes = New-Aes $header[8..15]
        $crypto = New-Object Security.Cryptography.CryptoStream $in, $aes.CreateDecryptor(), ([Security.Cryptography.CryptoStreamMode]::Read)
        $out = [IO.File]::Create($target)
        try { $crypto.CopyTo($out, 8MB) } finally { $out.Dispose(); $crypto.Dispose(); $aes.Dispose() }
    } finally { $in.Dispose(); $owner.Dispose() }
}

function Read-ArtifactText([string] $path) {
    $in, $owner = Open-Artifact $path
    try { (New-Object IO.StreamReader $in).ReadToEnd().Trim() } finally { $in.Dispose(); $owner.Dispose() }
}

function Hex([byte[]] $bytes) { -join ($bytes | ForEach-Object { $_.ToString('x2') }) }

# ---- 1. upload ----
function Send-Inputs {
    $files = @(@{ role = 'game'; path = $Game })
    if ($Update) { $files += @{ role = 'update'; path = $Update } }
    $tempDir = Join-Path $store 'upload'
    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
    if ($Fonts) {   # the firmware or font folder travels as one zip
        $zip = Join-Path $tempDir 'fonts.zip'
        if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip }
        Compress-Archive -Path (Join-Path (Resolve-Path -LiteralPath $Fonts).Path '*') -DestinationPath $zip -CompressionLevel NoCompression
        $files += @{ role = 'fonts'; path = $zip }
    }

    $existing = @{}
    $draft = GhJson api "repos/$Repo/releases?per_page=100" | Where-Object { $_.tag_name -eq $Release } | Select-Object -First 1
    if ($draft) {
        foreach ($asset in $draft.assets) { $existing[$asset.name] = [long]$asset.size }
    } else {
        gh release create $Release -R $Repo --draft --title 'TOTK input (encrypted)' --notes 'Encrypted game files for the Build iPhone IPA workflow. Made by .github/pc/build-ipa.ps1; deleted once the IPA is back.'
        if ($LASTEXITCODE) { throw 'could not create the draft release' }
    }
    if ($existing.ContainsKey('manifest.json')) { gh release delete-asset $Release manifest.json -R $Repo --yes | Out-Null }

    $manifest = @{ version = 1; iter = $Iter; files = @() }
    foreach ($file in $files) {
        $item = Get-Item -LiteralPath $file.path
        $count = [Math]::Max(1, [Math]::Ceiling($item.Length / $PieceSize))
        $pieces = @()
        $sha = [Security.Cryptography.SHA256]::Create()
        $source = [IO.File]::OpenRead($item.FullName)
        try {
            for ($i = 0; $i -lt $count; $i++) {
                $name = '{0}.{1:d3}.enc' -f $item.Name, $i
                $length = [Math]::Min([long]$PieceSize, $item.Length - $i * [long]$PieceSize)
                # AES-CBC with PKCS7: 16 bytes of header plus the length rounded up to the next 16 bytes
                $encrypted = 16 + ([Math]::Floor($length / 16) + 1) * 16
                $pieces += $name
                if ($existing[$name] -eq $encrypted) {
                    Write-Host "$name already uploaded"
                    Copy-Bytes $source $length $sha $null
                    continue
                }
                $path = Join-Path $tempDir $name
                Write-Host ("encrypting {0} ({1} of {2})" -f $name, ($i + 1), $count)
                Protect-Piece $source $length $path $sha
                for ($try = 1; ; $try++) {
                    Write-Host "uploading $name"
                    gh release upload $Release $path -R $Repo --clobber
                    if ($LASTEXITCODE -eq 0) { break }
                    if ($try -ge 3) { throw "could not upload $name; run the script again to continue" }
                }
                Remove-Item -LiteralPath $path
            }
            [void] $sha.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        } finally { $source.Dispose() }
        $manifest.files += @{ role = $file.role; name = $item.Name; size = $item.Length; sha256 = (Hex $sha.Hash); pieces = $pieces }
    }
    $manifestPath = Join-Path $tempDir 'manifest.json'
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 5))
    gh release upload $Release $manifestPath -R $Repo --clobber
    if ($LASTEXITCODE) { throw 'could not upload manifest.json' }
    if ($Fonts) { Remove-Item -LiteralPath (Join-Path $tempDir 'fonts.zip') }
}

# ---- 3. receive ----
function Receive-Ipa {
    $all = @((GhJson api "repos/$Repo/actions/artifacts?per_page=100").artifacts | Where-Object { -not $_.expired })
    $ipa = $all | Where-Object { $_.name -like 'TOTK-*.ipa.enc' } | Sort-Object { [datetime]$_.created_at } -Descending | Select-Object -First 1
    if (-not $ipa) { throw "no IPA waiting on GitHub: https://github.com/$Repo/actions" }
    $plain = $ipa.name.Substring(0, $ipa.name.Length - 4)
    $sum = $all | Where-Object { $_.name -eq "$plain.sha256" -and $_.workflow_run.id -eq $ipa.workflow_run.id } | Select-Object -First 1
    if (-not $OutDir) { $script:OutDir = Join-Path $env:USERPROFILE 'Downloads' }
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $encrypted = Join-Path $OutDir $ipa.name
    $target = Join-Path $OutDir $plain
    $token = (gh auth token | Select-Object -Last 1)

    Write-Host ("downloading {0} ({1:N1} GB)" -f $ipa.name, ($ipa.size_in_bytes / 1GB))
    curl.exe -fL --retry 5 -C - -H "Authorization: Bearer $token" -o $encrypted "https://api.github.com/repos/$Repo/actions/artifacts/$($ipa.id)/zip"
    if ($LASTEXITCODE) { throw 'the download failed; run the script with -Receive again to continue it' }
    $expected = $null
    if ($sum) {
        $sumPath = Join-Path $store "$plain.sha256"
        curl.exe -fsSL -H "Authorization: Bearer $token" -o $sumPath "https://api.github.com/repos/$Repo/actions/artifacts/$($sum.id)/zip"
        if ($LASTEXITCODE -eq 0) { $expected = Read-ArtifactText $sumPath; Remove-Item -LiteralPath $sumPath }
    }

    Write-Host "decrypting into $target"
    Unprotect-File $encrypted $target
    $actual = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($expected -and $actual -ne $expected) { throw "$target does not match the SHA-256 the run recorded; the encrypted copy is kept" }
    Remove-Item -LiteralPath $encrypted
    foreach ($artifact in @($ipa, $sum)) { if ($artifact) { Quiet gh api -X DELETE "repos/$Repo/actions/artifacts/$($artifact.id)" } }
    $target
}

# ---- the steps ----
if ($Receive) {
    $ipaPath = Receive-Ipa
    Write-Host "IPA ready: $ipaPath" -ForegroundColor Green
    if (-not $KeepInputs) { Quiet gh release delete $Release -R $Repo --yes; Write-Host 'removed the uploaded game files from GitHub' }
    return
}
if (-not $Game) { throw 'give -Game <your XCI or NSP>, or -Receive to download a finished IPA' }
$Game = (Resolve-Path -LiteralPath $Game).Path
if ($Update) { $Update = (Resolve-Path -LiteralPath $Update).Path }

gh secret set FILE_PASS -R $Repo --body $pass   # as an argument: Windows PowerShell can put a byte-order mark before piped text
if ($LASTEXITCODE) { throw 'could not set the FILE_PASS secret' }
if ($Keys) {
    gh secret set PROD_KEYS -R $Repo --body (Get-Content -LiteralPath $Keys -Raw)
    if ($LASTEXITCODE) { throw 'could not set the PROD_KEYS secret' }
} elseif (-not $Test) {
    $names = GhJson secret list -R $Repo --json name | ForEach-Object { $_.name }
    if ($names -notcontains 'PROD_KEYS') { throw 'the PROD_KEYS secret is not set: add -Keys <path to your prod.keys>' }
}

Send-Inputs

$mode = if ($Test) { 'transfer-test' } else { 'build' }
$before = @(GhJson run list -R $Repo --workflow build-ipa.yml -L 20 --json databaseId | ForEach-Object { $_.databaseId })
gh workflow run build-ipa.yml -R $Repo -f "mode=$mode" -f "runner=$Runner" | Out-Null
if ($LASTEXITCODE) { throw 'could not start the workflow' }
$run = $null
for ($i = 0; $i -lt 30 -and -not $run; $i++) {
    Start-Sleep -Seconds 2
    $run = GhJson run list -R $Repo --workflow build-ipa.yml -L 20 --json databaseId |
        ForEach-Object { $_.databaseId } | Where-Object { $before -notcontains $_ } | Select-Object -First 1
}
if (-not $run) { throw "the workflow started but its run did not show up: https://github.com/$Repo/actions" }
Write-Host "run: https://github.com/$Repo/actions/runs/$run"
Write-Host 'You can close this window and switch the PC off now; afterwards, run this script with -Receive.'
Write-Host 'Or leave it open and it downloads the IPA when the run is done.'

$state = $null; $last = ''
do {
    Start-Sleep -Seconds 30
    try { $state = GhJson run view $run -R $Repo --json 'status,conclusion,jobs' } catch { continue }   # offline for a moment
    $step = @($state.jobs | ForEach-Object { $_.steps } | Where-Object { $_.status -eq 'in_progress' } |
        ForEach-Object { $_.name }) | Select-Object -First 1
    $now = if ($state.status -ne 'in_progress') { $state.status } elseif ($step) { $step } else { 'starting' }
    if ($now -ne $last) { Write-Host "$(Get-Date -Format HH:mm)  $now"; $last = $now }
} while (-not $state -or $state.status -ne 'completed')
if ($state.conclusion -ne 'success') { throw "the run failed: https://github.com/$Repo/actions/runs/$run (the game files stay uploaded for another try)" }

$ipaPath = Receive-Ipa
if ($Test) {
    Remove-Item -LiteralPath $ipaPath
    Write-Host 'transfer test passed: the game files went up and a 200 MB stand-in came back intact' -ForegroundColor Green
} else {
    Write-Host "IPA ready: $ipaPath" -ForegroundColor Green
    if (-not $KeepInputs) { Quiet gh release delete $Release -R $Repo --yes; Write-Host 'removed the uploaded game files from GitHub' }
}
