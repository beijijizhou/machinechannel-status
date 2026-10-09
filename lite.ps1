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
#   the owner's commands on this computer: lite.ps1 -Remote on | off | status   (off unless turned on here)
#
# What it carries out (and nothing else: it starts no program a message names - but see "remote"):
#   app "halooai"  {"do": "status"}                              the browser extension's version here
#                  {"do": "update", "version", "sha256", "url"}  fetch that package, check it, put its
#                                                                files into the extension's folder
#                                                                (manifest.json last: the extension
#                                                                reloads itself when it changes)
#   app "channel"  {"do": "ping"}
#                  {"do": "update", "sha256"}                    replace this script with the published one
#   app "remote"   {"command", "shell": "powershell"|"cmd", "timeout_s"}   the owner's hands on this computer:
#                  runs the command as the person the task runs as and answers what it printed. Only
#                  on a computer where someone sat down and ran "lite.ps1 -Remote on" (a file here,
#                  remote.on); no message can turn it on. The channel takes messages for "remote" from
#                  the admin key (or a key issued for the app "remote") and from nobody else. A command
#                  is carried out when this script next runs: within ten minutes, or at once when the
#                  browser is told to look (mc-push with p_machine).
#
# It also keeps machine.json in the extension's folder: {"pass", "machine", "label"}. The pass is
# worked out from this computer's key and is not the key: a service the extension talks to shows
# it to the channel (mc_whoami) to learn that this is a computer the owner approved. It opens
# nothing of the channel, and stops being accepted when the computer's key is revoked.
param(
    [string]$Token = "",
    [string]$Name = "",
    [ValidateSet("shop", "none")][string]$Kind = "shop",
    [string]$Dir = (Join-Path $env:LOCALAPPDATA "MachineChannelLite"),
    [string]$Extension = (Join-Path $env:LOCALAPPDATA "HalooAIAssistant"),
    [int]$EveryMinutes = 10,
    [string]$TaskName = "MachineChannelLite",
    [switch]$NoTask,
    [ValidateSet("", "on", "off", "status")][string]$Remote = "",   # the switch of the app "remote", thrown at this computer only
    [switch]$Native,      # started by Chrome for the extension (native messaging): one run now instead of at the next ten minutes
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$Channel = @{ url = "https://ziveajlinhmafqcweahx.supabase.co"; key = "sb_publishable_WoafNUwm9EwmDfrrinrvbQ_iQlIQwsF"; script = "https://beijijizhou.github.io/machinechannel-status/lite.ps1" }
$Revision = "ca2a508541b7"
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

# Written only when it would differ: the extension reads it every minute.
function WritePass {
    try {
        if (-not $script:Machine -or -not (Test-Path -LiteralPath $Extension -PathType Container)) { return }
        $inner = Sha256 ([Text.Encoding]::UTF8.GetBytes($script:Key))
        $pass = "mcp_" + (Sha256 ([Text.Encoding]::UTF8.GetBytes("machinechannel-pass:$inner")))
        $label = $null; if ($script:Label) { $label = $script:Label }
        $text = ([ordered]@{ pass = $pass; machine = $script:Machine; label = $label } | ConvertTo-Json -Compress)
        $file = Join-Path $Extension "machine.json"
        $now = ""; try { $now = [IO.File]::ReadAllText($file) } catch { }
        if ($now -ne $text) { [IO.File]::WriteAllText($file, $text, $plain) }
    } catch { }
}

# ---- the extension's line to this script ---------------------------------------------------------
# A release is pushed to the extension (a browser push: nothing of ours stays connected), and the
# extension cannot write its own files - so it has Chrome start this script once, there and then,
# instead of waiting for the task's next ten minutes. Chrome starts only what is entered for it:
# a file that names this script and the extensions that may ask, and a key of this user in the
# registry that points to the file. No administrator. What the extension hands over is the
# address its pushes go to, which the channel is then told with the rest (Beat).
$HostName = "com.machinechannel.lite"

# Chrome's id of an extension loaded from a folder is made of the folder's path. Both ways of
# knowing it are taken: worked out from the path, and read from what Chrome keeps of its profiles.
function ExtensionIds {
    $ids = @()
    try {
        $full = [IO.Path]::GetFullPath($Extension).TrimEnd('\')
        if ($full -match '^[a-z]:') { $full = $full.Substring(0, 1).ToUpper() + $full.Substring(1) }
        $hex = (Sha256 ([Text.Encoding]::Unicode.GetBytes($full))).Substring(0, 32)
        $ids += -join ($hex.ToCharArray() | ForEach-Object { [char](97 + [Convert]::ToInt32("$_", 16)) })
    } catch { }
    try {
        $escaped = (ConvertTo-Json ([IO.Path]::GetFullPath($Extension).TrimEnd('\'))).Trim('"')   # as a path stands in Chrome's JSON
        $profiles = Join-Path $env:LOCALAPPDATA "Google\Chrome\User Data"
        foreach ($file in @(Get-ChildItem -LiteralPath $profiles -Directory -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName "Secure Preferences"; Join-Path $_.FullName "Preferences" })) {
            if (-not (Test-Path -LiteralPath $file)) { continue }
            $text = [IO.File]::ReadAllText($file)
            $at = $text.IndexOf('"path":"' + $escaped + '"', [StringComparison]::OrdinalIgnoreCase)
            while ($at -ge 0) {
                $before = [regex]::Matches($text.Substring([Math]::Max(0, $at - 20000), [Math]::Min($at, 20000)), '"([a-p]{32})":\{')
                if ($before.Count) { $ids += $before[$before.Count - 1].Groups[1].Value }
                $at = $text.IndexOf('"path":"' + $escaped + '"', $at + 1, [StringComparison]::OrdinalIgnoreCase)
            }
        }
    } catch { }
    return @($ids | Where-Object { $_ -match '^[a-p]{32}$' } | Select-Object -Unique)
}

# Entered for Chrome, and written again only when something of it would differ.
function EnterNative {
    try {
        if (-not (Test-Path -LiteralPath $Extension -PathType Container)) { return }
        $ids = @(ExtensionIds)
        if (-not $ids.Count) { return }
        $cmd = Join-Path $Dir "native.cmd"
        $line = "@echo off`r`npowershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ""$(Join-Path $Dir 'lite.ps1')"" -Dir ""$Dir"" -Extension ""$Extension"" -EveryMinutes $EveryMinutes -Native`r`n"
        $json = ([ordered]@{ name = $HostName; description = "MachineChannel: one run of the light end, asked for by the extension";
            path = $cmd; type = "stdio"; allowed_origins = @($ids | ForEach-Object { "chrome-extension://$_/" }) } | ConvertTo-Json -Compress)
        $file = Join-Path $Dir "$HostName.json"
        foreach ($pair in @(@($cmd, $line), @($file, $json))) {
            $now = ""; try { $now = [IO.File]::ReadAllText($pair[0]) } catch { }
            if ($now -ne $pair[1]) { [IO.File]::WriteAllText($pair[0], $pair[1], $plain) }
        }
        $key = "HKCU:\Software\Google\Chrome\NativeMessagingHosts\$HostName"
        $has = ""; try { $has = "$((Get-Item -LiteralPath $key -ErrorAction Stop).GetValue(''))" } catch { }
        if ($has -ne $file) { New-Item -Path $key -Force | Out-Null; Set-Item -LiteralPath $key -Value $file }
        $script:NativeIds = $ids
    } catch { Note "native messaging not entered: $($_.Exception.Message)" }
}

# What Chrome hands over and takes back: four bytes of length, then JSON.
function NativeRead {
    try {
        $in = [Console]::OpenStandardInput()
        $head = New-Object byte[] 4
        if ($in.Read($head, 0, 4) -ne 4) { return $null }
        $length = [BitConverter]::ToInt32($head, 0)
        if ($length -le 0 -or $length -gt 65536) { return $null }
        $bytes = New-Object byte[] $length
        $got = 0
        while ($got -lt $length) { $n = $in.Read($bytes, $got, $length - $got); if ($n -le 0) { return $null }; $got += $n }
        return ([Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json)
    } catch { return $null }
}

function NativeWrite($answer) {
    if (-not $Native -or $script:NativeSaid) { return }
    $script:NativeSaid = $true
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($answer | ConvertTo-Json -Compress))
        $out = [Console]::OpenStandardOutput()
        $out.Write([BitConverter]::GetBytes([int]$bytes.Length), 0, 4)
        $out.Write($bytes, 0, $bytes.Length)
        $out.Flush()
    } catch { }
}

# The address the extension's pushes go to, as it last told it: kept in a file, told to the channel.
function PushAddress {
    try { $a = [IO.File]::ReadAllText((Join-Path $Dir "push.txt")).Trim(); if ($a -match '^https://[A-Za-z0-9.-]+/[\x21-\x7e]{1,700}$') { return $a } } catch { }
    return $null
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

# ---- the app "remote" ----------------------------------------------------------------------------
function RemoteOn { return (Test-Path -LiteralPath (Join-Path $Dir "remote.on")) }

# The command goes into a file of its own (never onto a command line) and what it prints into
# another: nothing is read through a pipe, so a program the command leaves running does not keep
# this run waiting. Stopped when it takes longer than asked (10 minutes unless said, 15 at most:
# the task itself is ended after 20).
function RunRemote($body) {
    $command, $shell = "$($body.command)", "$($body.shell)"
    if (-not $shell) { $shell = "powershell" }
    if (-not $command.Trim() -or $shell -notin @("powershell", "cmd")) { throw 'remote needs "command" (text) and "shell": "powershell" (the default) or "cmd"' }
    $seconds = 600; try { if ($body.timeout_s) { $seconds = [int]$body.timeout_s } } catch { }
    $seconds = [Math]::Max(5, [Math]::Min($seconds, 900))
    $folder = Join-Path $Dir "remote"
    New-Item -ItemType Directory -Force $folder | Out-Null
    $base = Join-Path $folder ([DateTime]::UtcNow.Ticks)
    $out, $err = "$base.out", "$base.err"
    try {
        if ($shell -eq "powershell") {
            $file = "$base.ps1"   # with a byte order mark, or Windows PowerShell reads it in the computer's own code page
            [IO.File]::WriteAllText($file, "[Console]::OutputEncoding = [Text.Encoding]::UTF8`r`n" + $command, (New-Object Text.UTF8Encoding $true))
            $exe, $arguments = "powershell.exe", "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ""$file"""
        } else {
            $file = "$base.cmd"
            [IO.File]::WriteAllText($file, "@echo off`r`nchcp 65001 >nul`r`n" + $command, $plain)
            $exe, $arguments = "cmd.exe", "/d /c ""$file"""
        }
        $p = Start-Process -FilePath $exe -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
        $null = $p.Handle   # or Windows PowerShell forgets the exit code
        $late = -not $p.WaitForExit($seconds * 1000)
        if ($late) { try { & taskkill.exe /PID $p.Id /T /F 2>$null | Out-Null } catch { } }
        $text = ""
        foreach ($f in @($out, $err)) { try { $text += [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8) } catch { } }
        if ($text.Length -gt 60000) { $text = $text.Substring($text.Length - 60000) }
        $exit = 1; if (-not $late) { $exit = $p.ExitCode }
        if ($late) { $text = ($text.Trim() + "`n(the command did not finish in $seconds s and was stopped)").Trim() }
        return @{ exit = $exit; output = $text.Trim() }
    } finally {   # the command may have carried something that should not lie around
        foreach ($f in @("$base.ps1", "$base.cmd", $out, $err)) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    }
}

function Carry($message) {
    $body = $message.body
    if ($message.app -eq "remote" -and (RemoteOn)) {
        $ran = RunRemote $body
        if ($ran.exit -ne 0) { throw "exit $($ran.exit)`n$($ran.output)" }
        return $ran.output
    }
    if ($message.app -eq "halooai") {
        if ($body.do -eq "status") { return @{ version = (ExtensionVersion); folder = $Extension; agent = $Revision } }
        if ($body.do -eq "update") { $done = UpdateExtension $body; WritePass; return $done }
        throw 'halooai knows "status" and "update"'
    }
    if ($message.app -eq "channel") {
        if ($body.do -eq "ping") { return @{ pong = $script:Machine; agent = "lite-$Revision"; halooai = (ExtensionVersion) } }
        if ($body.do -eq "update") { return (UpdateSelf $body) }
        throw 'the light end of the channel knows "ping" and "update"'
    }
    throw "no app '$($message.app)' on this machine"
}

function Beat([bool]$take = $true) {
    $apps = @("halooai"); if (RemoteOn) { $apps += "remote" }
    $info = @{ agent = "lite-$Revision"; apps = $apps; beat = $EveryMinutes * 60; versions = @{ halooai = (ExtensionVersion) }; user = $env:USERNAME }
    EnterNative
    if ($script:NativeIds) { $info["native"] = @($script:NativeIds) }   # which extensions may start this script: for the owner to see
    $push = PushAddress
    if ($push) { $info["push"] = $push }
    $answer = Rpc "mc_beat" @{ p_info = $info; p_take = $take }
    $script:Machine = "$($answer.machine)"
    $script:Label = "$($answer.label)"
    WritePass
    return @($answer.messages)
}

# ---- remove ------------------------------------------------------------------------------------
if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "The channel's task is removed. The extension's folder ($Extension) is left as it is."
    exit 0
}

# ---- the switch of the app "remote", at this computer ---------------------------------------------
if ($Remote) {
    $mark = Join-Path $Dir "remote.on"
    if ($Remote -eq "on") { New-Item -ItemType Directory -Force $Dir | Out-Null; [IO.File]::WriteAllText($mark, "turned on $(Get-Date -Format s) by $env:USERNAME", $plain) }
    if ($Remote -eq "off") { Remove-Item -LiteralPath $mark -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $mark) { Write-Host "remote: on  (this computer carries out the owner's commands; the channel knows within $EveryMinutes minutes)" }
    else { Write-Host "remote: off (no command is carried out; turn on with: lite.ps1 -Remote on)" }
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
if ($Native) {
    $asked = NativeRead
    try {
        $address = "$($asked.push)"
        if ($address -match '^https://[A-Za-z0-9.-]+/[\x21-\x7e]{1,700}$') {
            $file = Join-Path $Dir "push.txt"
            $now = ""; try { $now = [IO.File]::ReadAllText($file) } catch { }
            if ($now -ne $address) { [IO.File]::WriteAllText($file, $address, $plain) }
        }
    } catch { }
}
try {
    for ($round = 0; $round -lt 6; $round++) {   # a message may be followed by another: look again, a few times
        $messages = @(Beat)   # one message alone would otherwise arrive as a bare object without a Count
        if (-not $messages.Count) { break }
        if ($Native) { Note "started by the extension: $($messages.Count) waiting" }
        foreach ($message in ($messages | Sort-Object id)) {
            try { $status = "done"; $done = Carry $message; $code = 0
                  if ($done -is [string]) { $reply = $done } else { $reply = ($done | ConvertTo-Json -Compress) } }
            catch { $status = "error"; $reply = "$($_.Exception.Message)"; $code = 1 }
            $short = "$reply"; if ($short.Length -gt 300) { $short = $short.Substring(0, 300) + "..." }
            Note "message $($message.id) $($message.app) $($message.body.do): $status $short"
            Rpc "mc_answer" @{ p_id = $message.id; p_status = $status; p_reply = $reply; p_exit_code = $code } | Out-Null
        }
        NativeWrite @{ version = (ExtensionVersion); agent = "lite-$Revision"; carried = $messages.Count }   # the extension need not wait for the look after
        Start-Sleep -Seconds 10
    }
} catch { Note "run failed: $($_.Exception.Message)" }
NativeWrite @{ version = (ExtensionVersion); agent = "lite-$Revision"; carried = 0 }
