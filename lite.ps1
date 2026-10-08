# MachineChannel, the light end: for a computer that only runs a browser (no Python, no GPU, no
# administrator). Windows PowerShell and one scheduled task; nothing stays running and there is
# no open connection. Every few minutes the task wakes this script, which says "I am here",
# takes what is waiting for this machine, carries it out, answers, and leaves.
#
#   install (once, as the person who uses the computer; no administrator needed), either:
#     lite.ps1 -Name LM               the computer makes its own key and asks to join under that
#                                     name; nothing works until the owner approves it on the
#                                     status page (the same command for every computer)
#     lite.ps1 -Token mc_...          a key the channel's owner issued for this one computer
#   every run after that is the task's:  lite.ps1
#   remove:                              lite.ps1 -Uninstall
#
# What it carries out (and nothing else: it starts no program a message names):
#   app "ecomai"   {"do": "status"}                              the browser extension's version here
#                  {"do": "update", "version", "sha256", "url"}  fetch that package, check it, put its
#                                                                files into the extension's folder
#                                                                (manifest.json last: the extension
#                                                                reloads itself when it changes)
#   app "channel"  {"do": "ping"}
#                  {"do": "update", "sha256"}                    replace this script with the published one
param(
    [string]$Token = "",
    [string]$Name = "",
    [ValidateSet("shop", "none")][string]$Kind = "shop",
    [string]$Dir = (Join-Path $env:LOCALAPPDATA "MachineChannelLite"),
    [string]$Extension = (Join-Path $env:LOCALAPPDATA "ImageGrab"),
    [int]$EveryMinutes = 10,
    [string]$TaskName = "MachineChannelLite",
    [switch]$NoTask,
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$Channel = @{ url = "https://ziveajlinhmafqcweahx.supabase.co"; key = "sb_publishable_WoafNUwm9EwmDfrrinrvbQ_iQlIQwsF"; script = "https://beijijizhou.github.io/machinechannel-status/lite.ps1" }
$Revision = "005a40a9ccde"
$plain = New-Object Text.UTF8Encoding $false
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Sha256([byte[]]$bytes) { -join ([Security.Cryptography.SHA256]::Create().ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) }
function Note([string]$text) { Add-Content -LiteralPath (Join-Path $Dir "lite.log") -Value "$(Get-Date -Format 'MM-dd HH:mm:ss') $text" -Encoding UTF8 }

# One call of a function of the channel. A refusal is thrown as plain text with the channel's own
# reason in it (Windows PowerShell does not always hand the reply's text over by itself).
function Call([string]$name, [hashtable]$fields) {
    $json = [Text.Encoding]::UTF8.GetBytes(($fields | ConvertTo-Json -Depth 8 -Compress))
    try {
        return Invoke-RestMethod -Method Post -Uri "$($Channel.url)/rest/v1/rpc/$name" -ContentType "application/json; charset=utf-8" `
            -Headers @{ apikey = $Channel.key } -Body $json -TimeoutSec 60
    } catch {
        $why = "$($_.ErrorDetails.Message)"
        if (-not $why -and $_.Exception.Response) {
            try { $stream = $_.Exception.Response.GetResponseStream(); $stream.Position = 0; $why = (New-Object IO.StreamReader($stream)).ReadToEnd() } catch { }
        }
        try { $why = "$(($why | ConvertFrom-Json).message)" } catch { }
        if (-not $why) { $why = "$($_.Exception.Message)" }
        throw "$why"
    }
}

function Rpc([string]$name, [hashtable]$fields) {
    $fields["p_token"] = $script:Key
    return (Call $name $fields)
}

function Fetch([string]$url, [int]$seconds) {   # to a file and back: the bytes exactly as they were sent
    $file = Join-Path $Dir "download.tmp"
    try { Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec $seconds -OutFile $file; return , [IO.File]::ReadAllBytes($file) }
    finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
}

function ExtensionVersion {
    try { return "$((Get-Content -LiteralPath (Join-Path $Extension 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json).version)" } catch { return "" }
}

function UpdateExtension($body) {
    $version, $want, $url = "$($body.version)", "$($body.sha256)".ToLower(), "$($body.url)"
    if ($version -notmatch '^[0-9][0-9.]{0,30}$' -or $want -notmatch '^[0-9a-f]{64}$' -or $url -notmatch '^https://') {
        throw 'update needs "version", "sha256" (64 hex characters) and an https "url"'
    }
    if ((ExtensionVersion) -eq $version) { return @{ version = $version; changed = $false; note = "already this version" } }
    $bytes = Fetch $url 300
    if ((Sha256 $bytes) -ne $want) { throw "the downloaded package does not match its sha256: nothing was changed" }
    Add-Type -AssemblyName System.IO.Compression
    $zip = New-Object IO.Compression.ZipArchive((New-Object IO.MemoryStream(, $bytes)))
    try {
        $entries = @($zip.Entries | Where-Object { -not $_.FullName.EndsWith("/") })
        if (-not ($entries | Where-Object { $_.FullName -eq "manifest.json" })) { throw "the package has no manifest.json at its top: nothing was changed" }
        if ($entries | Where-Object { $_.FullName -match '(^|/)\.\.(/|$)|^/|:' }) { throw "the package names a file outside its folder: nothing was changed" }
        New-Item -ItemType Directory -Force $Extension | Out-Null
        foreach ($e in ($entries | Sort-Object { $_.FullName -eq "manifest.json" })) {   # manifest.json last
            $target = Join-Path $Extension ($e.FullName -replace "/", "\")
            New-Item -ItemType Directory -Force (Split-Path $target -Parent) | Out-Null
            $in = $e.Open(); $out = [IO.File]::Create($target)
            try { $in.CopyTo($out) } finally { $out.Dispose(); $in.Dispose() }
        }
    } finally { $zip.Dispose() }
    return @{ version = (ExtensionVersion); changed = $true; files = $entries.Count }
}

function UpdateSelf($body) {
    $want = "$($body.sha256)".ToLower()
    if ($want -notmatch '^[0-9a-f]{64}$') { throw 'the script update needs "sha256"' }
    $bytes = Fetch "$($Channel.script)?t=$([DateTime]::UtcNow.Ticks)" 120
    if ((Sha256 $bytes) -ne $want) { throw "the published script does not match the sha256 that was ordered: not replaced" }
    [IO.File]::WriteAllBytes((Join-Path $Dir "lite.ps1"), $bytes)
    return @{ updated = $true; note = "the next run uses it" }
}

function Carry($message) {
    $body = $message.body
    if ($message.app -eq "ecomai") {
        if ($body.do -eq "status") { return @{ version = (ExtensionVersion); folder = $Extension; agent = $Revision } }
        if ($body.do -eq "update") { return (UpdateExtension $body) }
        throw 'ecomai knows "status" and "update"'
    }
    if ($message.app -eq "channel") {
        if ($body.do -eq "ping") { return @{ pong = $script:Machine; agent = "lite-$Revision"; ecomai = (ExtensionVersion) } }
        if ($body.do -eq "update") { return (UpdateSelf $body) }
        throw 'the light end of the channel knows "ping" and "update"'
    }
    throw "no app '$($message.app)' on this machine"
}

function Beat([bool]$take = $true) {
    $info = @{ agent = "lite-$Revision"; apps = @("ecomai"); beat = $EveryMinutes * 60; versions = @{ ecomai = (ExtensionVersion) }; user = $env:USERNAME }
    $answer = Rpc "mc_beat" @{ p_info = $info; p_take = $take }
    $script:Machine = "$($answer.machine)"
    return @($answer.messages)
}

# ---- remove ------------------------------------------------------------------------------------
if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "The channel's task is removed. The extension's folder ($Extension) is left as it is."
    exit 0
}

# ---- install -----------------------------------------------------------------------------------
$code = ""
if ($Name -and -not $Token) {
    # This computer's own key, made here; the channel is told its sha256 and keeps it waiting.
    $random = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($random)
    $Token = "mc_" + (-join ($random | ForEach-Object { $_.ToString("x2") }))
    $ask = @{ p_sha256 = (Sha256 ([Text.Encoding]::UTF8.GetBytes($Token))); p_machine = $Name.Trim(); p_kind = $Kind; p_note = "asked to join from $env:COMPUTERNAME ($env:USERNAME)" }
    try { $asked = Call "mc_join" $ask }
    catch { Write-Host "NOT installed: the channel did not take the request. $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
    $code = "$($asked.code)"
}
if ($Token) {
    New-Item -ItemType Directory -Force $Dir, $Extension | Out-Null
    [IO.File]::WriteAllText((Join-Path $Dir "channel.token"), $Token.Trim(), $plain)
    if ($PSCommandPath -and ((Resolve-Path $PSCommandPath).Path -ne (Join-Path $Dir "lite.ps1"))) { Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $Dir "lite.ps1") -Force }
    $script:Key = $Token.Trim()
    if ($code) {
        Write-Host ""
        Write-Host "Asked to join as '$Name'.  Code: $code" -ForegroundColor Yellow
        Write-Host "Tell the owner this name and code; waiting for the approval on the status page (up to 10 minutes)..."
        for ($i = 0; $i -lt 40; $i++) {   # only while someone is installing: afterwards the task asks every few minutes
            try { $null = Beat $false; $code = ""; break }
            catch { if ("$($_.Exception.Message)" -notmatch "approval") { Write-Host "  (could not ask: $($_.Exception.Message))"; break } }
            Start-Sleep -Seconds 15
        }
    }
    if ($code) { Write-Host "Not approved yet. That is fine: this computer keeps asking and comes on the channel once the owner approves." -ForegroundColor Yellow }
    else { try { $null = Beat $false } catch { Write-Host "NOT installed: the channel did not accept this machine's key. $($_.Exception.Message)" -ForegroundColor Red; exit 1 } }
    if (-not $NoTask) {
        # wscript starts PowerShell without a window, so nothing flashes on the screen every few minutes.
        $run = Join-Path $Dir "run.vbs"
        $line = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ""$(Join-Path $Dir 'lite.ps1')"" -Dir ""$Dir"" -Extension ""$Extension"" -EveryMinutes $EveryMinutes"
        [IO.File]::WriteAllText($run, "CreateObject(""WScript.Shell"").Run """ + $line.Replace('"', '""') + """, 0, False", [Text.Encoding]::Unicode)
        $action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$run`""
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes $EveryMinutes)
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 20)
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
        if (-not $code) {
            Start-ScheduledTask -TaskName $TaskName   # the first run now: a release that is waiting arrives at once
            for ($i = 0; $i -lt 20 -and -not (ExtensionVersion); $i++) { Start-Sleep -Seconds 3 }
        }
    }
    Write-Host ""
    if ($code) { Write-Host "Installed, waiting for approval (name '$Name', code $code). It asks every $EveryMinutes minutes." -ForegroundColor Yellow }
    else { Write-Host "Installed: this computer is on the channel as '$($script:Machine)' and asks every $EveryMinutes minutes." -ForegroundColor Green }
    Write-Host "Extension folder: $Extension   (version here: $(if (ExtensionVersion) { ExtensionVersion } else { 'none yet - it arrives with the first update' }))"
    Write-Host ""
    Write-Host "What is left to do by hand, once:"
    Write-Host "  1. Chrome -> chrome://extensions -> turn on 'Developer mode' -> 'Load unpacked' -> choose the folder above"
    Write-Host "     (after the first update has put the extension there)."
    Write-Host "  2. Open the extension's panel and enter the passcode you were given."
    exit 0
}

# ---- one run of the task -----------------------------------------------------------------------
try { $script:Key = (Get-Content -LiteralPath (Join-Path $Dir "channel.token") -Raw).Trim() } catch { exit 2 }
try {
    for ($round = 0; $round -lt 6; $round++) {   # a message may be followed by another: look again, a few times
        $messages = @(Beat)   # one message alone would otherwise arrive as a bare object without a Count
        if (-not $messages.Count) { break }
        foreach ($message in ($messages | Sort-Object id)) {
            try { $status = "done"; $reply = (Carry $message | ConvertTo-Json -Compress); $code = 0 }
            catch { $status = "error"; $reply = "$($_.Exception.Message)"; $code = 1 }
            Note "message $($message.id) $($message.app) $($message.body.do): $status $reply"
            Rpc "mc_answer" @{ p_id = $message.id; p_status = $status; p_reply = $reply; p_exit_code = $code } | Out-Null
        }
        Start-Sleep -Seconds 10
    }
} catch { Note "run failed: $($_.Exception.Message)" }
