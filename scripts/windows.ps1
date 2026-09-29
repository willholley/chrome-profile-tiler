# Chrome Profile Tiler - Windows
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
    EXTENSION_ID     = "nlmmgnhgdeffjkdckmikfpnddkbbfkkk"
    STARTUP_URL      = ""
    SET_STARTUP_PAGE = "yes"
    PROFILE_COUNT    = "12"
    SOURCE_PROFILE   = "Profile 1"
    COPY_TO          = "ALL"
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
  if ($cfg["EXTENSION_ID"] -notmatch '^[a-p]{32}$') {
    $problems += "EXTENSION_ID should be 32 letters (a-p). Copy it from the Chrome Web Store URL."
  }
  foreach ($k in "PROFILE_COUNT", "DELAY_MIN", "DELAY_MAX", "INSTALL_TIMEOUT", "MAX_SCREENS") {
    if ($cfg[$k] -notmatch '^\d+$') { $problems += "$k must be a whole number." }
  }
  if ($cfg["SOURCE_PROFILE"] -notmatch '^(Default|Profile \d+)$') {
    $problems += "SOURCE_PROFILE should look like 'Profile 2' or 'Default'."
  }
  if ($problems.Count -eq 0) {
    if ([int]$cfg["PROFILE_COUNT"] -lt 1) { $problems += "PROFILE_COUNT must be at least 1." }
    if ([int]$cfg["DELAY_MIN"] -gt [int]$cfg["DELAY_MAX"]) { $problems += "DELAY_MIN can't be bigger than DELAY_MAX." }
  }
  if ($problems.Count -gt 0) {
    foreach ($p in $problems) { Write-Host "config.txt: $p" -ForegroundColor Red }
    return $false
  }

  $script:ExtId          = $cfg["EXTENSION_ID"]
  $script:StartupUrl     = $cfg["STARTUP_URL"]
  $script:SetStartup     = ($cfg["SET_STARTUP_PAGE"] -eq "yes")
  $script:ProfileCount   = [int]$cfg["PROFILE_COUNT"]
  $script:Source         = $cfg["SOURCE_PROFILE"]
  $script:CopyTo         = $cfg["COPY_TO"]
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

function New-ChromeProfiles {
  if (-not (Confirm-ChromeClosed)) { return $false }
  Write-Host "Opening each profile once so Chrome installs the extension."
  Write-Host "(Profiles that don't exist yet are created.)"
  $total = $Profiles.Count
  $i = 0
  $missing = 0
  foreach ($p in $Profiles) {
    $i++
    $extDir = Join-Path $UserData "$p\Extensions\$ExtId"
    Write-Host "[$(Get-Date -Format HH:mm:ss)] ($i/$total) $p"
    Start-Process $ChromeExe -ArgumentList @("--profile-directory=`"$p`"", "about:blank")
    $waited = 0
    while (-not (Test-Path $extDir) -and $waited -lt $InstallTimeout) {
      Start-Sleep -Seconds 2
      $waited += 2
    }
    if (Test-Path $extDir) {
      Start-Sleep -Seconds 4
      Write-Host "    extension installed"
    } else {
      Write-Host "    WARNING: the extension didn't appear within ${InstallTimeout}s." -ForegroundColor Yellow
      $missing++
    }
    Stop-Chrome
  }
  if ($missing -gt 0) {
    Write-Host ""
    Write-Host "$missing profile(s) did not get the extension. Check that the policy is installed"
    Write-Host "(open chrome://policy in Chrome), then run this step again."
    return $false
  }
  return $true
}

function Open-PrimaryProfile {
  Write-Host "Opening $Source."
  Write-Host "Set up the extension there (its options/settings page), then close Chrome"
  Write-Host "completely and choose 'Copy primary settings' from the menu."
  Start-Process $ChromeExe -ArgumentList @("--profile-directory=`"$Source`"", "chrome://extensions")
}

function Get-CopyTargets {
  if ($CopyTo -eq "" -or $CopyTo -eq "ALL") {
    return @($Profiles | Where-Object { $_ -ne $Source })
  }
  return @($CopyTo.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" -and $_ -ne $Source })
}

function Copy-Settings {
  $src = Join-Path $UserData $Source
  if (-not (Test-Path (Join-Path $src "Local Extension Settings\$ExtId"))) {
    Write-Host "$Source has no saved settings for this extension yet."
    Write-Host "Choose 'Open primary profile' from the menu, set the extension up, close Chrome, then try again."
    return
  }

  $targets = @(Get-CopyTargets)
  if ($targets.Count -eq 0) {
    Write-Host "There are no other profiles to copy to (check COPY_TO in config.txt)."
    return
  }
  Write-Host "This will REPLACE the extension's saved settings in these profiles"
  Write-Host "with the settings from ${Source}:"
  foreach ($t in $targets) { Write-Host "  - $t" }
  Write-Host "(Whatever is there now is backed up first.)"
  if (-not (Read-YesNo "Continue?")) { Write-Host "Cancelled."; return }
  if (-not (Confirm-ChromeClosed)) { return }

  $areas  = @("Local Extension Settings", "Sync Extension Settings")
  $backup = Join-Path $RepoDir ("generated\backup-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
  $copied = 0
  foreach ($p in $targets) {
    $profileDir = Join-Path $UserData $p
    if (-not (Test-Path $profileDir)) {
      Write-Host "${p}: profile folder doesn't exist yet (run first-time setup) - skipped"
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
  Write-Host "Copied settings from $Source to $copied profile(s)."
  if (Test-Path $backup) { Write-Host "Previous settings were backed up to: $backup" }
  Write-Host "If a profile is signed in to a Google account with Chrome sync on, Chrome may"
  Write-Host "overwrite the copy. Use the extension's own Export/Import for those."
}

function Show-Status {
  Write-Host "Chrome data folder: $UserData"
  Write-Host "Extension: $ExtId"
  if (Test-PolicyInstalled) { Write-Host "Policy: installed" } else { Write-Host "Policy: NOT installed" }
  Write-Host ""
  Write-Host ("{0,-12} {1,-11} {2}" -f "PROFILE", "EXTENSION", "SAVED SETTINGS")
  $list = @($Source) + @($Profiles | Where-Object { $_ -ne $Source })
  foreach ($p in $list) {
    $dir = Join-Path $UserData $p
    if (-not (Test-Path $dir)) {
      Write-Host ("{0,-12} {1}" -f $p, "(profile not created yet)")
      continue
    }
    $inst = "no"
    if (Test-Path (Join-Path $dir "Extensions\$ExtId")) { $inst = "yes" }
    $sd = Join-Path $dir "Local Extension Settings\$ExtId"
    $size = "none"
    if (Test-Path $sd) {
      $bytes = (Get-ChildItem $sd -Recurse -File | Measure-Object Length -Sum).Sum
      $size = "{0} KB" -f [math]::Round($bytes / 1KB, 1)
    }
    $note = ""
    if ($p -eq $Source) { $note = "   <- primary" }
    Write-Host ("{0,-12} {1,-11} {2}{3}" -f $p, $inst, $size, $note)
  }
  Write-Host ""
  Write-Host "Tip: a configured profile usually has a much larger 'saved settings' size than a fresh one."
}

function Start-FirstTimeSetup {
  Install-Policy
  if (-not (Test-PolicyInstalled)) {
    Write-Host "The policy isn't installed, so I'm stopping here." -ForegroundColor Yellow
    return
  }
  if (-not (New-ChromeProfiles)) { return }
  Write-Host ""
  Write-Host "First-time setup finished. Next:"
  Write-Host "  2) Open primary profile - configure the extension there"
  Write-Host "  3) Copy primary settings to the other profiles"
  Write-Host "  4) Launch all profiles, tiled"
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

function Start-TiledLaunch {
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

  Write-Host "Opening $n profiles with a $DelayMin-$DelayMax second pause between each."
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
    $delay = Get-Random -Minimum $DelayMin -Maximum ($DelayMax + 1)
    Write-Host "    waiting ${delay}s..."
    Start-Sleep -Seconds $delay
  }
  Write-Host "Done."
}

# ---------------------------------------------------------------- menu

function Invoke-Action($name) {
  switch ($name) {
    "setup"          { Start-FirstTimeSetup }
    "policy-install" { Install-Policy }
    "policy-remove"  { Remove-Policy }
    "open-primary"   { Open-PrimaryProfile }
    "copy"           { Copy-Settings }
    "launch"         { Start-TiledLaunch }
    "status"         { Show-Status }
    default          { Write-Host "Unknown action: $name" }
  }
}

function Show-Menu {
  while ($true) {
    Clear-Host
    Write-Host "=============================================="
    Write-Host "  Chrome Profile Tiler"
    Write-Host "=============================================="
    Write-Host "  Extension : $ExtId"
    Write-Host "  Profiles  : Profile 1 - Profile $ProfileCount   (primary: $Source)"
    Write-Host ""
    Write-Host "  1) First-time setup (install policy, create profiles, install extension)"
    Write-Host "  2) Open primary profile (to configure the extension)"
    Write-Host "  3) Copy primary settings to the other profiles"
    Write-Host "  4) Launch all profiles, tiled across your screens"
    Write-Host "  5) Check status"
    Write-Host "  6) Remove the policy (undo step 1)"
    Write-Host "  Q) Quit"
    Write-Host ""
    $choice = (Read-Host "Choose an option").Trim().ToUpper()
    Write-Host ""
    switch ($choice) {
      "1" { Invoke-Action "setup" }
      "2" { Invoke-Action "open-primary" }
      "3" { Invoke-Action "copy" }
      "4" { Invoke-Action "launch" }
      "5" { Invoke-Action "status" }
      "6" { Invoke-Action "policy-remove" }
      "Q" { return }
      default { Write-Host "Please choose 1-6 or Q." }
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
