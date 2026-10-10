# Put a machine on MachineChannel, from nothing: fetch the published agent through the channel,
# check it, unpack it and run its installer. For a machine that has no other project's installer
# to do this for it. Safe to run again (it updates).
#
#   powershell -ExecutionPolicy Bypass -File bootstrap.ps1 -Join UV5                (the same line for every machine: no key in it)
#   powershell -ExecutionPolicy Bypass -File bootstrap.ps1 -Token mc_...            (a machine key of this computer)
#   powershell -ExecutionPolicy Bypass -File bootstrap.ps1 -Token mc_... -Dir D:\MachineChannel
#
# -Join <what people call the machine>: the computer makes its own key and asks to join under its
# computer name; nothing is installed until the owner approves the request on the status page
# (the six-character code shown here is shown there too). The name given is only said to the
# owner with the request: it is the owner who names the machine. No key is typed or copied.
#
# The machine key is issued on the channel's status page (kind "机器钥匙", name = this computer's
# name, i.e. what `echo %COMPUTERNAME%` prints). It only lets this one machine report and take
# its own messages. A machine without Python 3.10 or newer gets Python 3.12 first (winget).
# The last line printed is one JSON object {"ok": true|false, ...}. Exit code 0 / 1.
param(
    [string]$Token = "",
    [string]$Join = "",
    [string]$Dir = "C:\MachineChannel",
    [string]$Python = "",
    [string]$TaskName = "MachineChannelAgent",
    [switch]$Remote   # also register the app "remote" (the owner's commands; scripts\remote.ps1 off ends it)
)

$ErrorActionPreference = "Stop"
$Channel = @{ url = "https://ziveajlinhmafqcweahx.supabase.co"; key = "sb_publishable_WoafNUwm9EwmDfrrinrvbQ_iQlIQwsF" }
$keep = @("var", "apps", ".venv", "output")   # this machine's own state: never replaced
$report = [ordered]@{ ok = $false; step = "start"; machine = $env:COMPUTERNAME }
function Done([bool]$ok) { $report.ok = $ok; ($report | ConvertTo-Json -Compress); exit ($(if ($ok) { 0 } else { 1 })) }

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    function Hex([byte[]]$b) { -join ($b | ForEach-Object { $_.ToString("x2") }) }
    if (-not $Token -and -not $Join) { throw "say -Join <what people call this machine> (or -Token <a machine key the owner issued>)" }
    if (-not $Token) {
        # This computer's own key, made here. The channel is told its sha256 and keeps the request waiting.
        $report.step = "ask to join"
        $kept = Join-Path $Dir "var\channel.token"
        if (Test-Path $kept) { $Token = [IO.File]::ReadAllText($kept).Trim() }   # asked before, or on the channel already: the same key
        else {
            $random = New-Object byte[] 32
            [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($random)
            $Token = "mc_" + (Hex $random)
        }
        $sha256 = Hex ([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($Token)))
        $ask = @{ p_sha256 = $sha256; p_machine = $env:COMPUTERNAME; p_kind = "none"; p_note = "asks to join as $($Join.Trim()) (from $env:USERNAME)" } | ConvertTo-Json -Compress
        $waiting = $true
        try {
            $asked = Invoke-RestMethod -Method Post -Uri "$($Channel.url)/rest/v1/rpc/mc_join" -ContentType "application/json; charset=utf-8" `
                -Headers @{ apikey = $Channel.key } -Body ([Text.Encoding]::UTF8.GetBytes($ask)) -TimeoutSec 60
            New-Item -ItemType Directory -Force (Join-Path $Dir "var") | Out-Null
            [IO.File]::WriteAllText($kept, $Token, (New-Object Text.UTF8Encoding $false))
            Write-Host ""
            Write-Host "Asked to join as '$env:COMPUTERNAME' ($($Join.Trim())).  Code: $($asked.code)" -ForegroundColor Yellow
            Write-Host "Waiting for the owner to approve it on the status page (up to 20 minutes)..."
        } catch {
            if ("$($_.ErrorDetails.Message)" -notmatch "already on the channel") { throw "the channel did not take the request: $(if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message })" }
            $waiting = $false   # this computer is on the channel with the key it has: go on to the install
        }
        $body = @{ p_token = $Token } | ConvertTo-Json -Compress
        for ($i = 0; $waiting -and $i -lt 80; $i++) {   # only while someone is installing
            try { $null = Invoke-RestMethod -Method Post -Uri "$($Channel.url)/rest/v1/rpc/mc_whoami" -ContentType "application/json" -Headers @{ apikey = $Channel.key } -Body $body -TimeoutSec 30; $waiting = $false }
            catch { Start-Sleep -Seconds 15 }
        }
        if ($waiting) { throw "not approved within 20 minutes: run the same line again once the owner has approved it (the request stays)" }
    }
    $report.step = "fetch"
    $body = @{ p_token = $Token.Trim() } | ConvertTo-Json -Compress
    try {
        $rel = Invoke-RestMethod -Method Post -Uri "$($Channel.url)/rest/v1/rpc/mc_release" -ContentType "application/json" `
            -Headers @{ apikey = $Channel.key } -Body $body -TimeoutSec 120
    } catch {
        $why = $_.ErrorDetails.Message
        throw "the channel did not hand out its agent: $(if ($why) { $why } else { $_.Exception.Message })"
    }
    $bytes = [Convert]::FromBase64String($rel.zip)
    $sha = -join ([Security.Cryptography.SHA256]::Create().ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") })
    if ($sha -ne $rel.sha256) { throw "the downloaded agent does not match its published sha256: not installed" }
    $report.revision = $rel.revision

    $report.step = "unpack"
    New-Item -ItemType Directory -Force $Dir | Out-Null
    Add-Type -AssemblyName System.IO.Compression
    $zip = New-Object IO.Compression.ZipArchive((New-Object IO.MemoryStream(, $bytes)))
    foreach ($e in $zip.Entries) {
        if ($e.FullName.EndsWith("/") -or ($keep -contains ($e.FullName -split "/")[0])) { continue }
        $target = Join-Path $Dir ($e.FullName -replace "/", "\")
        New-Item -ItemType Directory -Force (Split-Path $target -Parent) | Out-Null
        $in = $e.Open(); $out = [IO.File]::Create($target)
        try { $in.CopyTo($out) } finally { $out.Dispose(); $in.Dispose() }
    }
    $zip.Dispose()

    # The agent is a Python program: a machine without Python 3.10+ gets 3.12 first (winget).
    $report.step = "python"
    if (-not $Python) {
        $found = $false
        foreach ($c in @("py", "python")) {
            try { $v = (& $c -c "import sys; print(sys.version_info[0] * 100 + sys.version_info[1])" 2>$null); if ([int]"$v" -ge 310) { $found = $true } } catch { }
        }
        foreach ($base in @("$env:LOCALAPPDATA\Programs\Python", "$env:ProgramFiles", "C:\")) {
            if (Get-ChildItem -Path $base -Filter "Python3*" -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path (Join-Path $_.FullName "python.exe") }) { $found = $true }
        }
        if (-not $found) {
            if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { throw "this machine has no Python 3.10+ and no winget to install it with: install Python 3.12 from python.org, then run this again" }
            Write-Host "== installing Python 3.12 (a few minutes)"
            & winget install --id Python.Python.3.12 --exact --silent --scope machine --accept-package-agreements --accept-source-agreements | Out-Null
            $report.python_installed = $true
        }
    }

    $report.step = "install"
    $env:MACHINECHANNEL_TOKEN = $Token.Trim()
    $installArgs = @("-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $Dir "scripts\install.ps1"),
              "-Revision", $rel.revision, "-TaskName", $TaskName)
    if ($Python) { $installArgs += @("-Python", $Python) }
    if ($Remote) { $installArgs += "-Remote" }
    $lines = & powershell.exe @installArgs
    $env:MACHINECHANNEL_TOKEN = $null
    $last = ($lines | Where-Object { "$_".Trim() } | Select-Object -Last 1)
    try { $inner = $last | ConvertFrom-Json } catch { $inner = $null }
    if (-not $inner -or -not $inner.ok) { throw "the agent's installer stopped at '$($inner.step)': $(if ($inner) { $inner.error } else { $last })" }
    $report.machine = $inner.machine
    $report.folder = $Dir
    $report.step = "installed"
    Done $true
}
catch {
    $report.error = "$($_.Exception.Message)"
    Done $false
}
