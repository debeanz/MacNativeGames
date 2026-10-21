<#
.SYNOPSIS
Builds the Tears of the Kingdom IPA on GitHub Actions straight from the game files on this PC, without cloud storage.

.DESCRIPTION
Shares the game file's folder through a temporary, password-protected Cloudflare quick tunnel (rclone serve webdav and
cloudflared, no Cloudflare account needed) and starts the "Build iPhone IPA" workflow on your fork. The runner downloads
the game files through that tunnel; when the IPA is built, it opens a tunnel of its own and this script downloads the
IPA through it (a Cloudflare tunnel takes at most 100 MB per upload, so the runner cannot simply send it back) and
checks its SHA-256. Each tunnel's address and password go only to the RCLONE_CONF secret or to the other side.

Keep the PC on and online until the script says the IPA is ready: the runner downloads the game files at the start and
the IPA comes back at the end, hours later. The script keeps Windows from sleeping while it runs.

Needs rclone (winget install Rclone.Rclone), cloudflared (winget install Cloudflare.cloudflared) and the GitHub CLI,
signed in (gh auth login). The update and the fonts folder must be in the game file's folder or a folder inside it.

.EXAMPLE
.\build-from-pc.ps1 -Game D:\Switch\totk.xci -Update D:\Switch\totk-1.4.3.nsp -Keys D:\Switch\prod.keys

.EXAMPLE
.\build-from-pc.ps1 -Game D:\Switch\totk.xci -Test
Moves 200 MB each way through the tunnels in a few minutes, without building, and shows the speeds.
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
$fields = @('-f', "game=$(RemotePath $Game)", '-f', 'output=pc:from-runner', '-f', 'pull=true', '-f', "runner=$Runner")
if ($Update) { $fields += @('-f', "update=$(RemotePath $Update)") }
if ($Fonts) { $fields += @('-f', "fonts=$(RemotePath $Fonts)") }
$mode = if ($Test) { 'transfer-test' } else { 'build' }
$fields += @('-f', "mode=$mode")

if ($Keys) {
    # Values go to gh and rclone as arguments: Windows PowerShell can put a byte-order mark in front of what it pipes
    gh secret set PROD_KEYS -R $Repo --body (Get-Content -LiteralPath $Keys -Raw)
    if ($LASTEXITCODE) { throw 'could not set the PROD_KEYS secret' }
} elseif (-not $Test) {
    $names = GhJson secret list -R $Repo --json name | ForEach-Object { $_.name }
    if ($names -notcontains 'PROD_KEYS') { throw 'the PROD_KEYS secret is not set: add -Keys <path to your prod.keys>' }
}

# The runner's side of the conversation: it leaves <name>.offer.json here and waits for <name>.done or <name>.failed;
# failed builds leave their logs in logs-run<n>
$inbox = Join-Path $root 'from-runner'
New-Item -ItemType Directory -Force -Path $inbox | Out-Null
$received = @()

# Downloads each file the runner offers (tunnel address, password, size, SHA-256) into the game file's folder, checks
# it, and answers with <name>.done, or <name>.failed after three tries
function Receive-Offers {
    foreach ($file in @(Get-ChildItem -LiteralPath $inbox -Filter '*.offer.json' -File)) {
        try { $offer = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json } catch { continue }   # still arriving
        if (-not $offer.sha256) { continue }
        $target = Join-Path $root $offer.name
        $obscured = rclone obscure $offer.pass | Select-Object -Last 1
        $from = ":webdav,url='$($offer.url)',vendor=other,user=$($offer.user),pass='$obscured':$($offer.name)"
        $good = $false
        for ($try = 1; $try -le 3 -and -not $good; $try++) {
            Write-Host ("downloading {0} ({1:N1} GB), try {2}" -f $offer.name, ($offer.size / 1GB), $try)
            rclone copyto $from $target --multi-thread-streams 8 --retries 3 --stats 30s --stats-one-line
            $good = ($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $target) -and
                ((Get-Item -LiteralPath $target).Length -eq [long]$offer.size) -and
                ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -eq $offer.sha256)
        }
        $answer = if ($good) { '.done' } else { '.failed' }
        [IO.File]::WriteAllText((Join-Path $inbox ($offer.name + $answer)), '')
        Remove-Item -LiteralPath $file.FullName
        if ($good) { $script:received += $target } else { Write-Host "$($offer.name) did not arrive intact" -ForegroundColor Red }
    }
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
    $obscured = rclone obscure $pass | Select-Object -Last 1
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
    gh secret set RCLONE_CONF -R $Repo --body $conf
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

    $state = $null; $last = ''
    do {
        Start-Sleep -Seconds 20
        Receive-Offers
        try { $state = GhJson run view $run -R $Repo --json 'status,conclusion,number,jobs' } catch { continue }   # offline for a moment
        $step = @($state.jobs | ForEach-Object { $_.steps } | Where-Object { $_.status -eq 'in_progress' } |
            ForEach-Object { $_.name }) | Select-Object -First 1
        $now = if ($state.status -ne 'in_progress') { $state.status } elseif ($step) { $step } else { 'starting' }
        if ($now -ne $last) { Write-Host "$(Get-Date -Format HH:mm)  $now"; $last = $now }
    } while (-not $state -or $state.status -ne 'completed')
    Receive-Offers
    $ok = ($state.conclusion -eq 'success')
    Get-ChildItem -LiteralPath $inbox -File | Where-Object { $_.Name -like '*.done' -or $_.Name -like '*.failed' } | Remove-Item

    if ($Test) {
        foreach ($f in $received) { Remove-Item -LiteralPath $f }
        if ($ok -and $received.Count) { Write-Host 'transfer test passed (speeds in the run summary)' -ForegroundColor Green }
        else { throw "transfer test failed: https://github.com/$Repo/actions/runs/$run" }
    } elseif ($ok -and $received.Count) {
        foreach ($f in $received) { Write-Host "IPA ready: $f" -ForegroundColor Green }
    } else {
        $logs = Join-Path $inbox "logs-run$($state.number)"
        if (Test-Path -LiteralPath $logs) { Write-Host "build logs: $logs" }
        throw "the build failed: https://github.com/$Repo/actions/runs/$run"
    }
} finally {
    foreach ($p in @($tunnel, $serve)) { if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } }
    [TotkBuild.Power]::SetThreadExecutionState([uint32]2147483648) | Out-Null   # ES_CONTINUOUS: sleep as usual again
    Quiet gh secret delete RCLONE_CONF -R $Repo   # its tunnel address is gone now anyway
}
