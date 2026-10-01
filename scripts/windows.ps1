# Stagehand - Windows
# Keep this file ASCII-only: Windows PowerShell 5.1 misreads non-ASCII
# characters in scripts that were saved without a byte-order mark.

param(
  [string]$Action = "menu",
  [switch]$PauseAtEnd
)

$RepoDir    = Split-Path -Parent $PSScriptRoot
$ConfigFile = Join-Path $RepoDir "config.txt"
$UserData   = Join-Path $env:LOCALAPPDATA "Google\Chrome\User Data"
if ($env:CHROME_DATA_DIR) { $UserData = $env:CHROME_DATA_DIR }
$PolicyRoot = "HKLM:\SOFTWARE\Policies\Google\Chrome"
$Pad        = 7   # compensates for the invisible borders Windows adds around windows

# ---------------------------------------------------------------- helpers

function Read-YesNo($question) {
  $a = Read-Host "$question [y/N]"
  return ($a -match '^(y|yes)$')
}

function Get-ChromeExe {
  $candidates = @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
  )
  foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
  return $null
}

function Test-ChromeRunning {
  return [bool](Get-Process chrome -ErrorAction SilentlyContinue)
}

function Stop-Chrome {
  $procs = @(Get-Process chrome -ErrorAction SilentlyContinue)
  if ($procs.Count -eq 0) { return }
  foreach ($p in $procs) {
    if ($p.MainWindowHandle -ne 0) { [void]$p.CloseMainWindow() }
  }
  for ($i = 0; $i -lt 20; $i++) {
    if (-not (Test-ChromeRunning)) { return }
    Start-Sleep -Milliseconds 500
  }
  Get-Process chrome -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Seconds 2
}

function Confirm-ChromeClosed {
  if (-not (Test-ChromeRunning)) { return $true }
  Write-Host "Chrome is running. It needs to be closed for this step."
  if (Read-YesNo "Close all Chrome windows now?") {
    Stop-Chrome
    return $true
  }
  Write-Host "Cancelled."
  return $false
}

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($id)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------- config

function Read-Settings {
  $cfg = @{
    STARTUP_URL      = ""
    SET_STARTUP_PAGE = "yes"
    PROFILE_COUNT    = "12"
    DELAY_MIN        = "45"
    DELAY_MAX        = "75"
    INSTALL_TIMEOUT  = "90"
    MAX_SCREENS      = "0"
  }

  if (-not (Test-Path $ConfigFile)) {
    Write-Host "Could not find config.txt at: $ConfigFile" -ForegroundColor Red
    return $false
  }

  foreach ($line in Get-Content $ConfigFile) {
    $l = $line.Trim()
    if ($l -eq "" -or $l.StartsWith("#")) { continue }
    $i = $l.IndexOf("=")
    if ($i -lt 1) { continue }
    $k = $l.Substring(0, $i).Trim()
    $v = $l.Substring($i + 1).Trim()
    if ($cfg.ContainsKey($k)) { $cfg[$k] = $v }
  }

  $problems = @()
  foreach ($k in "PROFILE_COUNT", "DELAY_MIN", "DELAY_MAX", "INSTALL_TIMEOUT", "MAX_SCREENS") {
    if ($cfg[$k] -notmatch '^\d+$') { $problems += "$k must be a whole number." }
  }
  if ($problems.Count -eq 0) {
    if ([int]$cfg["PROFILE_COUNT"] -lt 1) { $problems += "PROFILE_COUNT must be at least 1." }
    if ([int]$cfg["DELAY_MIN"] -gt [int]$cfg["DELAY_MAX"]) { $problems += "DELAY_MIN can't be bigger than DELAY_MAX." }
  }
  if ($problems.Count -gt 0) {
    foreach ($p in $problems) { Write-Host "config.txt: $p" -ForegroundColor Red }
    return $false
  }

  # Lightning Autofill is the only extension this tool manages
  $script:ExtId          = "nlmmgnhgdeffjkdckmikfpnddkbbfkkk"
  $script:ExtName        = "Lightning Autofill"
  # The master profile: a dedicated Chrome profile where the extension is set up by hand.
  # Its settings get copied into Profile 1 ... Profile N.
  $script:MasterProfile  = "Autofill Master"
  $script:StartupUrl     = $cfg["STARTUP_URL"]
  $script:SetStartup     = ($cfg["SET_STARTUP_PAGE"] -eq "yes")
  $script:ProfileCount   = [int]$cfg["PROFILE_COUNT"]
  $script:DelayMin       = [int]$cfg["DELAY_MIN"]
  $script:DelayMax       = [int]$cfg["DELAY_MAX"]
  $script:InstallTimeout = [int]$cfg["INSTALL_TIMEOUT"]
  $script:MaxScreens     = [int]$cfg["MAX_SCREENS"]
  $script:Profiles       = @(1..$script:ProfileCount | ForEach-Object { "Profile $_" })
  return $true
}

# ---------------------------------------------------------------- policy

function Get-ListEntries($key) {
  if (-not (Test-Path $key)) { return }
  $item = Get-Item $key
  foreach ($n in $item.GetValueNames()) {
    [pscustomobject]@{ Name = $n; Value = [string]$item.GetValue($n) }
  }
}

function Add-ListEntry($key, $value, $byPrefix) {
  $existing = @(Get-ListEntries $key)
  foreach ($e in $existing) {
    if ($byPrefix) { if ($e.Value.StartsWith($value)) { return } }
    elseif ($e.Value -eq $value) { return }
  }
  $used = @($existing | ForEach-Object { $_.Name })
  $idx = 1
  while ($used -contains "$idx") { $idx++ }
  New-ItemProperty -Path $key -Name "$idx" -PropertyType String -Value $value -Force | Out-Null
}

function Remove-ListEntry($key, $value, $byPrefix) {
  foreach ($e in @(Get-ListEntries $key)) {
    $hit = $false
    if ($byPrefix) { $hit = $e.Value.StartsWith($value) } else { $hit = ($e.Value -eq $value) }
    if ($hit) { Remove-ItemProperty -Path $key -Name $e.Name -ErrorAction SilentlyContinue }
  }
  if ((Test-Path $key) -and (@(Get-ListEntries $key).Count -eq 0)) {
    Remove-Item $key -Force -ErrorAction SilentlyContinue
  }
}

function Invoke-Elevated($act) {
  $argString = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Action $act -PauseAtEnd"
  try {
    Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $argString -Wait -ErrorAction Stop
  } catch {
    Write-Host "Administrator permission wasn't granted, so nothing was changed." -ForegroundColor Yellow
  }
}

function Test-PolicyInstalled {
  $entries = @(Get-ListEntries "$PolicyRoot\ExtensionInstallForcelist")
  foreach ($e in $entries) { if ($e.Value.StartsWith("$ExtId;")) { return $true } }
  return $false
}

function Install-Policy {
  if (-not (Test-Admin)) {
    Write-Host "Windows will now ask for permission (a UAC prompt) to set Chrome's policy..."
    Invoke-Elevated "policy-install"
    return
  }
  $listKey = "$PolicyRoot\ExtensionInstallForcelist"
  # Note: New-Item -Force on an existing registry key can wipe it, so only create when missing.
  if (-not (Test-Path $listKey)) { New-Item -Path $listKey -Force | Out-Null }
  Add-ListEntry $listKey "$ExtId;https://clients2.google.com/service/update2/crx" $false

  if ($SetStartup -and $StartupUrl -ne "") {
    New-ItemProperty -Path $PolicyRoot -Name "RestoreOnStartup" -PropertyType DWord -Value 4 -Force | Out-Null
    $urlKey = "$PolicyRoot\RestoreOnStartupURLs"
    if (-not (Test-Path $urlKey)) { New-Item -Path $urlKey -Force | Out-Null }
    Add-ListEntry $urlKey $StartupUrl $false
  }
  Write-Host "Policy written. Chrome picks it up the next time it starts."
  Write-Host "You can confirm at chrome://policy in Chrome."
}

function Remove-Policy {
  if (-not (Test-Admin)) {
    Write-Host "Windows will now ask for permission (a UAC prompt) to remove Chrome's policy..."
    Invoke-Elevated "policy-remove"
    return
  }
  Remove-ListEntry "$PolicyRoot\ExtensionInstallForcelist" "$ExtId;" $true
  if ($StartupUrl -ne "") {
    $urlKey = "$PolicyRoot\RestoreOnStartupURLs"
    Remove-ListEntry $urlKey $StartupUrl $false
    if (-not (Test-Path $urlKey)) {
      Remove-ItemProperty -Path $PolicyRoot -Name "RestoreOnStartup" -ErrorAction SilentlyContinue
    }
  }
  Write-Host "Policy removed. Restart Chrome; chrome://policy should no longer list these settings."
}

# ---------------------------------------------------------------- profiles

# Opens one profile just long enough for the policy to install the extension in it.
# Returns $true if the extension is there afterwards, $false if it never appeared.
function Install-ExtensionIn($p) {
  $extDir = Join-Path $UserData "$p\Extensions\$ExtId"
  if (-not (Test-Path $extDir)) {
    Start-Process $ChromeExe -ArgumentList @("--profile-directory=`"$p`"", "about:blank")
    $waited = 0
    while (-not (Test-Path $extDir) -and $waited -lt $InstallTimeout) {
      Start-Sleep -Seconds 2
      $waited += 2
    }
    if (Test-Path $extDir) { Start-Sleep -Seconds 4 }
    Stop-Chrome
  }
  return (Test-Path $extDir)
}

function Open-MasterProfile {
  Write-Host "Opening the master profile."
  Write-Host "This is a separate Chrome profile just for setting up $ExtName by hand."
  Write-Host "The first time, it can take up to a minute for the extension to appear."
  Write-Host ""
  Write-Host "When Chrome opens:"
  Write-Host "  - If it asks you to sign in or turn on sync, choose 'Don't sign in'."
  Write-Host "  - Follow your Autofill instructions to set up $ExtName."
  Write-Host "  - When you've finished and clicked Save, close Chrome completely."
  Write-Host "Then come back here and choose step 3."
  Start-Process $ChromeExe -ArgumentList @("--profile-directory=`"$MasterProfile`"", "--new-window")
}


function Copy-Master {
  $src = Join-Path $UserData $MasterProfile
  $srcLocal = Join-Path $src "Local Extension Settings\$ExtId"
  if (-not (Test-Path $srcLocal)) {
    Write-Host "The master profile has no $ExtName settings yet."
    Write-Host "Choose step 2, set up $ExtName there and click Save, close Chrome,"
    Write-Host "then come back to step 3."
    return
  }
  $bytes = (Get-ChildItem $srcLocal -Recurse -File | Measure-Object Length -Sum).Sum
  $kb = [math]::Round($bytes / 1KB, 0)
  if ($kb -lt 8) {
    Write-Host "The master profile's $ExtName looks almost empty ($kb KB of settings)."
    Write-Host "Did you activate it, import the rules and click Save? A set-up profile is usually much bigger."
    if (-not (Read-YesNo "Copy it anyway?")) { Write-Host "Cancelled."; return }
  }

  Write-Host "This copies the master profile's $ExtName settings (key, rules and options) into"
  Write-Host "Profile 1 - Profile $ProfileCount, creating any of those profiles that don't exist yet."
  Write-Host "Anything $ExtName has stored in them is replaced (it's backed up first)."
  if (-not (Read-YesNo "Continue?")) { Write-Host "Cancelled."; return }
  if (-not (Confirm-ChromeClosed)) { return }

  # 1. make sure every profile exists and has the extension installed
  $total = $Profiles.Count
  $i = 0
  $tried = 0
  foreach ($p in $Profiles) {
    $i++
    if (Test-Path (Join-Path $UserData "$p\Extensions\$ExtId")) { continue }
    $tried++
    Write-Host "[$(Get-Date -Format HH:mm:ss)] ($i/$total) ${p}: creating it and installing the extension..."
    if (Install-ExtensionIn $p) {
      Write-Host "    done"
    } else {
      Write-Host "    WARNING: the extension didn't appear within ${InstallTimeout}s." -ForegroundColor Yellow
      if ($tried -eq 1) {
        Write-Host ""
        Write-Host "That usually means the one-time setup (step 1) isn't finished, so Chrome isn't"
        Write-Host "installing the extension. Open chrome://policy in Chrome to check, then run step 1 again."
        return
      }
    }
  }

  # 2. copy the master's settings into each profile
  $areas  = @("Local Extension Settings", "Sync Extension Settings")
  $backup = Join-Path $RepoDir ("generated\backup-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
  $copied = 0
  foreach ($p in $Profiles) {
    $profileDir = Join-Path $UserData $p
    if (-not (Test-Path (Join-Path $profileDir "Extensions\$ExtId"))) {
      Write-Host "${p}: skipped (the extension isn't installed there)"
      continue
    }
    foreach ($a in $areas) {
      $from = Join-Path $src "$a\$ExtId"
      if (-not (Test-Path $from)) { continue }
      $destParent = Join-Path $profileDir $a
      $dest = Join-Path $destParent $ExtId
      if (Test-Path $dest) {
        $bk = Join-Path $backup "$p\$a"
        New-Item -ItemType Directory -Path $bk -Force | Out-Null
        Copy-Item $dest $bk -Recurse -Force
        Remove-Item $dest -Recurse -Force
      }
      New-Item -ItemType Directory -Path $destParent -Force | Out-Null
      Copy-Item $from $dest -Recurse -Force
    }
    Write-Host "${p}: copied"
    $copied++
  }

  Write-Host ""
  Write-Host "Copied the master profile to $copied of $total profiles."
  if (Test-Path $backup) { Write-Host "What was there before is backed up in: $backup" }
  Write-Host ""
  Write-Host "Next, check one copy: open it (step 4 or 5), then in $ExtName's Options look for"
  Write-Host "'Activated' on the Settings tab and your rules on the Form Fields tab."
}

function Show-Status {
  Write-Host "Chrome data folder: $UserData"
  Write-Host "Extension: $ExtName ($ExtId)"
  if (Test-PolicyInstalled) { Write-Host "Policy: installed" } else { Write-Host "Policy: NOT installed" }
  Write-Host ""
  Write-Host ("{0,-18} {1,-11} {2}" -f "PROFILE", "EXTENSION", "SAVED SETTINGS")
  $list = @($MasterProfile) + @($Profiles)
  foreach ($p in $list) {
    $note = ""
    if ($p -eq $MasterProfile) { $note = "   <- master" }
    $dir = Join-Path $UserData $p
    if (-not (Test-Path $dir)) {
      Write-Host ("{0,-18} {1}{2}" -f $p, "(not created yet)", $note)
      continue
    }
    $inst = "no"
    if (Test-Path (Join-Path $dir "Extensions\$ExtId")) { $inst = "yes" }
    $sd = Join-Path $dir "Local Extension Settings\$ExtId"
    $size = "none"
    if (Test-Path $sd) {
      $bytes = (Get-ChildItem $sd -Recurse -File | Measure-Object Length -Sum).Sum
      $size = "{0} KB" -f [math]::Round($bytes / 1KB, 0)
    }
    Write-Host ("{0,-18} {1,-11} {2}{3}" -f $p, $inst, $size, $note)
  }
  Write-Host ""
  Write-Host "A profile that has been set up usually shows a much bigger 'saved settings' size than a"
  Write-Host "fresh one. After step 3, every copy should be close to the master's size."
}

function Start-OneTimeSetup {
  Install-Policy
  if (-not (Test-PolicyInstalled)) {
    Write-Host "The policy isn't installed, so I'm stopping here." -ForegroundColor Yellow
    return
  }
  Write-Host ""
  Write-Host "One-time setup finished. Next, choose step 2 to open the master profile."
}

# ---------------------------------------------------------------- uninstall

function Confirm-PolicyRemoval {
  Write-Host "Heads up: removing the policy also removes $ExtName."
  Write-Host "Chrome treats the extension as managed by the policy, so it will uninstall it from"
  Write-Host "EVERY profile the next time Chrome starts, along with the extension's saved settings."
  Write-Host "The startup page set by the policy goes away too."
  Write-Host ""
  Write-Host "Only continue if you're finished with the extension, or you plan to install it"
  Write-Host "yourself from the Chrome Web Store afterwards (it will start empty)."
  Write-Host ""
  return (Read-YesNo "Remove the policy anyway?")
}

# Removes profile folders from Chrome's profile list (the "Local State" file).
# Chrome must be closed. Keeps a backup copy and puts it back if anything goes wrong.
function Update-LocalState($names) {
  $ls = Join-Path $UserData "Local State"
  if (-not (Test-Path $ls)) { return $true }
  $bkDir = Join-Path $RepoDir "generated"
  New-Item -ItemType Directory -Path $bkDir -Force | Out-Null
  $bk = Join-Path $bkDir ("Local State.backup-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
  try {
    Copy-Item $ls $bk -Force -ErrorAction Stop
    $raw  = [System.IO.File]::ReadAllText($ls)
    $obj  = $raw | ConvertFrom-Json
    $prof = $obj.profile
    if ($prof) {
      if ($prof.info_cache) {
        foreach ($n in $names) { [void]$prof.info_cache.PSObject.Properties.Remove($n) }
      }
      foreach ($k in @("profiles_order", "last_active_profiles")) {
        if ($prof.PSObject.Properties[$k]) {
          $prof.$k = @($prof.$k | Where-Object { $names -notcontains $_ })
        }
      }
      if ($prof.PSObject.Properties["last_used"] -and ($names -contains $prof.last_used)) {
        $prof.last_used = "Default"
      }
    }
    $json = $obj | ConvertTo-Json -Depth 100 -Compress
    [void]($json | ConvertFrom-Json)   # must parse again before anything is overwritten
    [System.IO.File]::WriteAllText($ls, $json, (New-Object System.Text.UTF8Encoding($false)))
    return $true
  } catch {
    if (Test-Path $bk) { Copy-Item $bk $ls -Force -ErrorAction SilentlyContinue }
    return $false
  }
}

function Remove-ChromeProfiles {
  $existing = @($Profiles | Where-Object { $_ -ne "Default" -and (Test-Path (Join-Path $UserData $_)) })
  if ($existing.Count -eq 0 -and -not (Test-Path (Join-Path $UserData $MasterProfile))) {
    Write-Host "None of the profiles exist, so there's nothing to delete."
    return
  }

  $list = @($existing)
  if (Test-Path (Join-Path $UserData $MasterProfile)) {
    Write-Host "Your master profile ($MasterProfile) is where $ExtName is set up by hand."
    Write-Host "Keeping it means you can copy it into new profiles again later."
    if (Read-YesNo "Delete the master profile too?") { $list += $MasterProfile }
  }
  if ($list.Count -eq 0) { Write-Host "Nothing left to delete."; return }

  Write-Host ""
  Write-Host "These profiles will be DELETED:"
  foreach ($p in $list) { Write-Host "  - $p" }
  Write-Host ""
  Write-Host "Everything in them goes: browsing history, bookmarks, saved passwords, cookies and"
  Write-Host "any accounts signed in there. Your Default profile is never touched."
  Write-Host "They are sent to the Recycle Bin where Windows allows it (a very large profile may"
  Write-Host "be deleted permanently instead)."
  Write-Host ""
  $typed = Read-Host "Type DELETE (in capitals) to continue"
  if ($typed -cne "DELETE") { Write-Host "Cancelled."; return }

  if (-not (Confirm-ChromeClosed)) { return }

  if (-not (Update-LocalState $list)) {
    Write-Host "I couldn't tidy Chrome's list of profiles (nothing was changed there)."
    if (-not (Read-YesNo "Delete the folders anyway? Chrome may then show empty leftover entries.")) {
      Write-Host "Cancelled."
      return
    }
  }

  Add-Type -AssemblyName Microsoft.VisualBasic
  $moved = 0
  foreach ($p in $list) {
    $dir = Join-Path $UserData $p
    try {
      [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
        $dir,
        [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
        [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
      Write-Host "${p}: deleted"
      $moved++
    } catch {
      Write-Host "${p}: couldn't be deleted ($($_.Exception.Message))" -ForegroundColor Yellow
    }
  }
  Write-Host ""
  Write-Host "Deleted $moved profile(s). Empty the Recycle Bin to free the space."
  Write-Host "If Chrome still shows a deleted profile in its profile picker, click the three dots on"
  Write-Host "that card and choose Delete."
  Write-Host "If you're removing everything, choose option 7 next to remove the policy."
}

# ---------------------------------------------------------------- tiling

function Initialize-WinApi {
  Add-Type -AssemblyName System.Windows.Forms
  if (-not ([System.Management.Automation.PSTypeName]'ChromeTilerWin').Type) {
    Add-Type @"
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class ChromeTilerWin {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc p, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int w, int hh, uint f);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  public static List<long> ChromeWindows() {
    var r = new List<long>();
    EnumWindows((h, l) => {
      if (IsWindowVisible(h)) {
        var sb = new StringBuilder(256);
        GetClassName(h, sb, 256);
        if (sb.ToString() == "Chrome_WidgetWin_1") r.Add(h.ToInt64());
      }
      return true;
    }, IntPtr.Zero);
    return r;
  }
}
"@
  }
  [ChromeTilerWin]::SetProcessDPIAware() | Out-Null
}

function Move-NewChromeWindow($before, $x, $y, $w, $h) {
  for ($t = 0; $t -lt 20; $t++) {
    Start-Sleep -Milliseconds 500
    $new = @([ChromeTilerWin]::ChromeWindows() | Where-Object { $before -notcontains $_ })
    if ($new.Count -gt 0) {
      # place twice: Chrome sometimes re-applies its saved size right after opening
      foreach ($pass in 1..2) {
        foreach ($hwnd in $new) {
          [ChromeTilerWin]::ShowWindow([IntPtr]$hwnd, 9) | Out-Null
          [ChromeTilerWin]::SetWindowPos([IntPtr]$hwnd, [IntPtr]::Zero, $x, $y, $w, $h, 0x0044) | Out-Null
        }
        Start-Sleep -Seconds 1
      }
      return
    }
  }
  Write-Host "    warning: couldn't find the new window to position" -ForegroundColor Yellow
}

function Start-TiledLaunch([bool]$Fast = $false) {
  $dMin = $DelayMin
  $dMax = $DelayMax
  if ($Fast) { $dMin = 1; $dMax = 1 }

  $missing = @($Profiles | Where-Object { -not (Test-Path (Join-Path $UserData $_)) })
  if ($missing.Count -gt 0) {
    Write-Host "These profiles don't exist yet: $($missing -join ', ')"
    Write-Host "Run step 3 first; it creates them and copies the master profile into them."
    return
  }

  Initialize-WinApi

  # primary screen first, then the others left to right
  $screens = @([System.Windows.Forms.Screen]::AllScreens |
    Sort-Object @{Expression = { -not $_.Primary } }, @{Expression = { $_.Bounds.X } })
  $ns = $screens.Count
  if ($MaxScreens -gt 0 -and $MaxScreens -lt $ns) { $ns = $MaxScreens }

  $n    = $Profiles.Count
  $base = [math]::Floor($n / $ns)
  $rem  = $n % $ns
  $slots = @()
  for ($s = 0; $s -lt $ns; $s++) {
    $cnt = $base
    if ($s -lt $rem) { $cnt = $base + 1 }
    if ($cnt -eq 0) { continue }
    $wa   = $screens[$s].WorkingArea
    $cols = [math]::Ceiling([math]::Sqrt($cnt))
    $rows = [math]::Ceiling($cnt / $cols)
    $cw   = [math]::Floor($wa.Width / $cols)
    $ch   = [math]::Floor($wa.Height / $rows)
    Write-Host "Screen $($s + 1): $cnt windows in a ${cols}x${rows} grid (${cw}x${ch} each)"
    for ($k = 0; $k -lt $cnt; $k++) {
      $c = $k % $cols
      $r = [math]::Floor($k / $cols)
      $slots += , @(($wa.X + $c * $cw - $Pad), ($wa.Y + $r * $ch), ($cw + 2 * $Pad), ($ch + $Pad))
    }
  }

  if ($dMin -eq $dMax) {
    Write-Host "Opening $n profiles with a $dMin second pause between each."
  } else {
    Write-Host "Opening $n profiles with a $dMin-$dMax second pause between each."
  }
  $i = 0
  foreach ($p in $Profiles) {
    $slot = $slots[$i]
    $i++
    Write-Host "[$(Get-Date -Format HH:mm:ss)] ($i/$n) Launching: $p"
    $chromeArgs = @("--profile-directory=`"$p`"", "--new-window")
    if ($StartupUrl -ne "") { $chromeArgs += $StartupUrl }
    $before = @([ChromeTilerWin]::ChromeWindows())
    Start-Process $ChromeExe -ArgumentList $chromeArgs
    Move-NewChromeWindow $before $slot[0] $slot[1] $slot[2] $slot[3]

    if ($i -eq $n) { break }
    $delay = Get-Random -Minimum $dMin -Maximum ($dMax + 1)
    for ($s = $delay; $s -gt 0; $s--) {
      Write-Host -NoNewline ("`r    next window in {0,3}s " -f $s)
      Start-Sleep -Seconds 1
    }
    Write-Host "`r    next window in   0s"
  }
  Write-Host "Done."
}

# ---------------------------------------------------------------- menu

function Invoke-Action($name) {
  switch ($name) {
    "setup"           { Start-OneTimeSetup }
    "policy-install"  { Install-Policy }
    "policy-remove"   { Remove-Policy }
    "open-master"     { Open-MasterProfile }
    "copy"            { Copy-Master }
    "launch"          { Start-TiledLaunch $false }
    "test-launch"     { Start-TiledLaunch $true }
    "status"          { Show-Status }
    "delete-profiles" { Remove-ChromeProfiles }
    default           { Write-Host "Unknown action: $name" }
  }
}

function Show-Banner {
  Write-Host @'

                         .
                        /|\
                       / | \
                      /  |  \
                     /   |   \
                    /____|____\
                   /  _______  \
                  /  |       |  \
                 /___|_______|___\
      \o/  o   \o/  o/  \o/  \o   o  \o/
       |  /|\   |   |    |    |  /|\  |
'@
  Write-Host "  =============================================="
  Write-Host "         Stagehand  -  $ExtName"
  Write-Host "  =============================================="
}

function Get-SettingsKB($dir) {
  if (-not (Test-Path $dir)) { return -1 }
  $bytes = (Get-ChildItem $dir -Recurse -File | Measure-Object Length -Sum).Sum
  return [math]::Round($bytes / 1KB, 0)
}

# Which setup steps look finished: an array of three booleans
function Get-Progress {
  $master = Join-Path $UserData $MasterProfile
  $policy = (Test-PolicyInstalled)
  $setUp  = ((Get-SettingsKB (Join-Path $master "Local Extension Settings\$ExtId")) -ge 8)
  $copied = $true
  foreach ($p in $Profiles) {
    if ((Get-SettingsKB (Join-Path $UserData "$p\Local Extension Settings\$ExtId")) -lt 8) { $copied = $false; break }
  }
  return @($policy, $setUp, $copied)
}

function Show-Menu {
  while ($true) {
    Clear-Host
    Show-Banner
    $done   = Get-Progress
    $labels = @(
      "Let Chrome install $ExtName for you",
      "Set up $ExtName in the master profile",
      "Copy the master into Profile 1 - Profile $ProfileCount"
    )
    $nextShown = $false
    Write-Host ""
    Write-Host "  Get set up (once)"
    for ($s = 0; $s -lt 3; $s++) {
      if ($done[$s]) {
        Write-Host "  [x] $($s + 1)) $($labels[$s])"
      } elseif (-not $nextShown) {
        Write-Host "  [ ] $($s + 1)) $($labels[$s])   <- next" -ForegroundColor Yellow
        $nextShown = $true
      } else {
        Write-Host "  [ ] $($s + 1)) $($labels[$s])"
      }
    }
    Write-Host ""
    Write-Host "  On the day"
    Write-Host "      4) Launch all the profiles"
    Write-Host "      5) Test launch (1-second pause instead of $DelayMin-$DelayMax)"
    Write-Host ""
    Write-Host "  More"
    Write-Host "      6) Check status"
    Write-Host "      7) Remove the policy (also removes the extension)"
    Write-Host "      8) Delete the profiles"
    Write-Host "      Q) Quit"
    Write-Host ""
    if (-not $nextShown) {
      Write-Host "  All set. Choose 5 to check the copies, or 4 when it's time." -ForegroundColor Green
      Write-Host ""
    }
    $choice = (Read-Host "Choose an option").Trim().ToUpper()
    Write-Host ""
    switch ($choice) {
      "1" { Invoke-Action "setup" }
      "2" { Invoke-Action "open-master" }
      "3" { Invoke-Action "copy" }
      "4" { Invoke-Action "launch" }
      "5" { Invoke-Action "test-launch" }
      "6" { Invoke-Action "status" }
      "7" {
        if (Confirm-PolicyRemoval) { Invoke-Action "policy-remove" } else { Write-Host "Cancelled." }
      }
      "8" { Invoke-Action "delete-profiles" }
      "Q" { return }
      default { Write-Host "Please choose 1-8 or Q." }
    }
    Write-Host ""
    Read-Host "Press Enter to return to the menu" | Out-Null
  }
}

# ---------------------------------------------------------------- main

if (-not (Read-Settings)) {
  Read-Host "Press Enter to close" | Out-Null
  exit 1
}

$ChromeExe = Get-ChromeExe
if (-not $ChromeExe) {
  Write-Host "Google Chrome wasn't found. Please install it first." -ForegroundColor Red
  Read-Host "Press Enter to close" | Out-Null
  exit 1
}

if ($Action -eq "menu") { Show-Menu } else { Invoke-Action $Action }

if ($PauseAtEnd) { Read-Host "Press Enter to close this window" | Out-Null }
