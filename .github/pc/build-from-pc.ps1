<#
.SYNOPSIS
Builds the Tears of the Kingdom IPA on GitHub Actions straight from the game files on this PC, without cloud storage.

.DESCRIPTION
Shares the game file's folder through a temporary, password-protected Cloudflare quick tunnel (rclone serve webdav and
cloudflared, no Cloudflare account needed), starts the "Build iPhone IPA" workflow on your fork, waits for it, and joins
the IPA it sends back in 90 MB parts. The tunnel address and its password go to the RCLONE_CONF secret only.

Keep the PC on and online until the script says the IPA is ready: the runner downloads the game files at the start and
uploads the IPA at the end, hours later. The script keeps Windows from sleeping while it runs.

Needs rclone (winget install Rclone.Rclone), cloudflared (winget install Cloudflare.cloudflared) and the GitHub CLI,
signed in (gh auth login). The update and the fonts folder must be in the game file's folder or a folder inside it.

.EXAMPLE
.\build-from-pc.ps1 -Game D:\Switch\totk.xci -Update D:\Switch\totk-1.4.3.nsp -Keys D:\Switch\prod.keys

.EXAMPLE
.\build-from-pc.ps1 -Game D:\Switch\totk.xci -Test
Moves 200 MB each way through the tunnel in a few minutes, without building, and shows the speeds.
#>
param(
    [Parameter(Mandatory = $true)] [string] $Game,
    [string] $Update,
    [string] $Fonts,
    [string] $Keys,
    [string] $Repo = 'debeanz/MacNativeGames',
    [ValidateSet('macos-26', 'macos-26-xlarge')] [string] $Runner = 'macos-26',
    [switch] $Test
)
$ErrorActionPreference = 'Stop'
$OutputEncoding = New-Object System.Text.UTF8Encoding $false   # what PowerShell pipes into gh and rclone

foreach ($tool in @(
        @('rclone', 'winget install Rclone.Rclone, then open a new PowerShell window'),
        @('cloudflared', 'winget install Cloudflare.cloudflared, then open a new PowerShell window'),
        @('gh', 'winget install GitHub.cli, then gh auth login'))) {
    if (-not (Get-Command $tool[0] -ErrorAction SilentlyContinue)) { throw "$($tool[0]) not found: $($tool[1])" }
}
# gh's JSON as objects; Out-String first, since Windows PowerShell's ConvertFrom-Json takes a piped document line by line
function GhJson { (& gh @args | Out-String) | ConvertFrom-Json }
# A native command with its output discarded; Windows PowerShell turns redirected stderr into errors that 'Stop' throws
function Quiet { $ErrorActionPreference = 'Continue'; $exe, $rest = $args; & $exe @rest *> $null }

# ---- what to share ----
$Game = (Resolve-Path -LiteralPath $Game).Path
$root = Split-Path -Parent $Game
$prefix = $root.TrimEnd('\') + '\'
function RemotePath([string] $path) {
    $full = (Resolve-Path -LiteralPath $path).Path
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$path must be in $root (the game file's folder) or a folder inside it"
    }
    'pc:' + $full.Substring($prefix.Length).Replace('\', '/')
}
$fields = @('-f', "game=$(RemotePath $Game)", '-f', 'output=pc:ipa-parts', '-f', 'split_upload=true', '-f', "runner=$Runner")
if ($Update) { $fields += @('-f', "update=$(RemotePath $Update)") }
if ($Fonts) { $fields += @('-f', "fonts=$(RemotePath $Fonts)") }
$mode = if ($Test) { 'transfer-test' } else { 'build' }
$fields += @('-f', "mode=$mode")

if ($Keys) {
    Get-Content -LiteralPath $Keys -Raw | gh secret set PROD_KEYS -R $Repo
    if ($LASTEXITCODE) { throw 'could not set the PROD_KEYS secret' }
} elseif (-not $Test) {
    $names = GhJson secret list -R $Repo --json name | ForEach-Object { $_.name }
    if ($names -notcontains 'PROD_KEYS') { throw 'the PROD_KEYS secret is not set: add -Keys <path to your prod.keys>' }
}

$parts = Join-Path $root 'ipa-parts'
New-Item -ItemType Directory -Force -Path $parts | Out-Null

# Joins every complete set of parts in ipa-parts (<name>.part-aaa, -aab, ... and <name>.sha256 = "<sha256> <size>") into
# <name> in the game file's folder, checks its size and SHA-256, then removes the parts.
function Join-Parts {
    $joined = @()
    foreach ($sum in @(Get-ChildItem -LiteralPath $parts -Filter '*.sha256' -File)) {
        $name = $sum.Name.Substring(0, $sum.Name.Length - '.sha256'.Length)
        $hash, $size = (Get-Content -LiteralPath $sum.FullName -Raw).Trim() -split '\s+'
        [string[]] $pieces = @(Get-ChildItem -LiteralPath $parts -Filter "$name.part-*" -File | ForEach-Object { $_.Name })
        [Array]::Sort($pieces, [StringComparer]::Ordinal)
        $target = Join-Path $root $name
        Write-Host "joining $($pieces.Count) parts into $target"
        $out = [IO.File]::Create($target)
        try {
            foreach ($piece in $pieces) {
                $in = [IO.File]::OpenRead((Join-Path $parts $piece))
                try { $in.CopyTo($out, 8MB) } finally { $in.Dispose() }
            }
        } finally { $out.Dispose() }
        $actual = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
        if ((Get-Item -LiteralPath $target).Length -ne [long]$size -or $actual -ne $hash) {
            throw "${name}: the joined file does not match what the runner sent (size or SHA-256); the parts stay in $parts"
        }
        foreach ($piece in $pieces) { Remove-Item -LiteralPath (Join-Path $parts $piece) }
        Remove-Item -LiteralPath $sum.FullName
        $joined += $target
    }
    $joined
}

Add-Type -Namespace TotkBuild -Name Power -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint flags);'
$work = Join-Path $env:TEMP ('totk-pc-build-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$serve = $null; $tunnel = $null
try {
    [TotkBuild.Power]::SetThreadExecutionState([uint32]2147483649) | Out-Null   # ES_CONTINUOUS | ES_SYSTEM_REQUIRED: no sleep

    # ---- the WebDAV server, on this PC only ----
    $bytes = New-Object byte[] 24
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $pass = [Convert]::ToBase64String($bytes).Replace('+', 'A').Replace('/', 'B').TrimEnd('=')
    $obscured = ($pass | rclone obscure -) | Select-Object -Last 1
    if ($LASTEXITCODE -or -not $obscured) { throw 'rclone obscure failed' }
    $listener = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback), 0
    $listener.Start(); $port = $listener.LocalEndpoint.Port; $listener.Stop()
    $serveRoot = if ($root.EndsWith('\')) { $root + '.' } else { $root }   # "D:\" would escape the closing quote
    $env:RCLONE_USER = 'totk'; $env:RCLONE_PASS = $pass   # rclone reads --user and --pass from these, off the command line
    try {
        $serve = Start-Process rclone -PassThru -WindowStyle Hidden -ArgumentList @(
            'serve', 'webdav', "`"$serveRoot`"", '--addr', "127.0.0.1:$port", '--log-file', "`"$work\rclone.log`"")
    } finally { Remove-Item Env:RCLONE_USER, Env:RCLONE_PASS }

    # ---- the tunnel; an empty config keeps a cloudflared config.yml from turning the quick tunnel off ----
    $empty = Join-Path $work 'empty.yml'
    [IO.File]::WriteAllText($empty, '')
    $tunnel = Start-Process cloudflared -PassThru -WindowStyle Hidden -RedirectStandardError "$work\cloudflared.log" `
        -RedirectStandardOutput "$work\cloudflared.out" -ArgumentList @(
            'tunnel', '--config', "`"$empty`"", '--no-autoupdate', '--url', "http://127.0.0.1:$port")
    $url = $null
    for ($i = 0; $i -lt 60 -and -not $url; $i++) {
        Start-Sleep -Seconds 1
        if ($tunnel.HasExited) { throw "cloudflared stopped; its log: $work\cloudflared.log" }
        $found = Select-String -LiteralPath "$work\cloudflared.log" -Pattern 'https://[a-z0-9-]+\.trycloudflare\.com' -AllMatches `
            -ErrorAction SilentlyContinue | ForEach-Object { $_.Matches } | ForEach-Object { $_.Value } |
            Where-Object { $_ -ne 'https://api.trycloudflare.com' } | Select-Object -First 1
        if ($found) { $url = $found }
    }
    if (-not $url) { throw "no tunnel address from cloudflared after 60 s; its log: $work\cloudflared.log" }
    Write-Host "tunnel up: $url"

    # The new address takes a few seconds to reach DNS; check it end to end, as the runner will use it
    $remote = ":webdav,url='$url',vendor=other,user=totk,pass='$obscured':"
    $reachable = $false
    for ($i = 0; $i -lt 30 -and -not $reachable; $i++) {
        Start-Sleep -Seconds 3
        Quiet rclone lsf $remote --max-depth 1
        $reachable = ($LASTEXITCODE -eq 0)
    }
    if (-not $reachable) { throw "the tunnel does not answer; logs: $work" }

    $conf = "[pc]`ntype = webdav`nurl = $url`nvendor = other`nuser = totk`npass = $obscured`n"
    $conf | gh secret set RCLONE_CONF -R $Repo
    if ($LASTEXITCODE) { throw 'could not set the RCLONE_CONF secret' }

    # ---- the run ----
    $before = @(GhJson run list -R $Repo --workflow build-ipa.yml -L 20 --json databaseId | ForEach-Object { $_.databaseId })
    gh workflow run build-ipa.yml -R $Repo @fields | Out-Null
    if ($LASTEXITCODE) { throw 'could not start the workflow' }
    $run = $null
    for ($i = 0; $i -lt 30 -and -not $run; $i++) {
        Start-Sleep -Seconds 2
        $run = GhJson run list -R $Repo --workflow build-ipa.yml -L 20 --json databaseId |
            ForEach-Object { $_.databaseId } | Where-Object { $before -notcontains $_ } | Select-Object -First 1
    }
    if (-not $run) { throw "the workflow started but its run did not show up: https://github.com/$Repo/actions" }
    Write-Host "run: https://github.com/$Repo/actions/runs/$run"
    Write-Host 'Keep this window open and the PC online. Free macOS runners can wait a while in the queue.'
    gh run watch $run -R $Repo --interval 60 --exit-status
    $ok = ($LASTEXITCODE -eq 0)
    $state = GhJson run view $run -R $Repo --json status,conclusion
    while ($state.status -ne 'completed') {   # gh run watch can return early on a network error
        Start-Sleep -Seconds 60
        $state = GhJson run view $run -R $Repo --json status,conclusion
        $ok = ($state.conclusion -eq 'success')
    }

    $files = @(Join-Parts)
    if ($Test) {
        foreach ($f in $files) { Remove-Item -LiteralPath $f }
        if ($ok -and $files.Count) { Write-Host 'transfer test passed: 200 MB each way (speeds in the run summary)' -ForegroundColor Green }
        else { throw "transfer test failed: https://github.com/$Repo/actions/runs/$run" }
    } elseif ($ok -and $files.Count) {
        foreach ($f in $files) { Write-Host "IPA ready: $f" -ForegroundColor Green }
    } else {
        $logs = Join-Path $parts "logs-run$((GhJson run view $run -R $Repo --json number).number)"
        if (Test-Path -LiteralPath $logs) { Write-Host "build logs: $logs" }
        throw "the build failed: https://github.com/$Repo/actions/runs/$run"
    }
} finally {
    foreach ($p in @($tunnel, $serve)) { if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } }
    [TotkBuild.Power]::SetThreadExecutionState([uint32]2147483648) | Out-Null   # ES_CONTINUOUS: sleep as usual again
    Quiet gh secret delete RCLONE_CONF -R $Repo   # its tunnel address is gone now anyway
}
