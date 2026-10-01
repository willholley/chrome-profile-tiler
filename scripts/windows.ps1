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
$ModeFile   = Join-Path $RepoDir "generated\install-mode"
$StoreUrl   = "https://chromewebstore.google.com/detail/lightning-autofill/nlmmgnhgdeffjkdckmikfpnddkbbfkkk"
$StoreTimeout = 300
$CopyStamp  = Join-Path $RepoDir "generated\last-copy"
$StartupUrlFile = Join-Path $RepoDir "generated\policy-startup-url"   # the startup page Stagehand put in the policy   # written after each copy, to spot later changes to the master
# Every merge to main is published as a release with these files attached (see .github/workflows)
$ReleasesUrl = "https://github.com/willholley/stagehand/releases/latest/download"
if ($env:RELEASES_URL) { $ReleasesUrl = $env:RELEASES_URL }

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

  $script:Cfg = $cfg   # the values as read, so Edit-Settings can offer them even if they're wrong
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

# Sets KEY=VALUE in config.txt, keeping its comments. Replaces the KEY= line if there is one,
# otherwise switches on a commented-out #KEY= line, otherwise adds the setting at the end.
function Set-ConfigValue($key, $value) {
  $lines = @()
  if (Test-Path $ConfigFile) { $lines = @(Get-Content $ConfigFile) }
  $active  = "^\s*$key\s*="
  $pattern = $active
  if (@($lines | Where-Object { $_ -match $active }).Count -eq 0) { $pattern = "^#\s*$key\s*=" }
  $out = New-Object System.Collections.Generic.List[string]
  $found = $false
  foreach ($l in $lines) {
    if (($l -match $pattern) -and ($pattern -eq $active -or -not $found)) {
      $out.Add("$key=$value")
      $found = $true
    } else {
      $out.Add($l)
    }
  }
  if (-not $found) { $out.Add("$key=$value") }
  [System.IO.File]::WriteAllLines($ConfigFile, $out, (New-Object System.Text.UTF8Encoding($false)))
}

# Asks a question, showing the current value; Enter keeps it
function Read-Value($question, $current) {
  $a = (Read-Host "$question [$current]").Trim()
  if ($a -eq "") { return $current }
  return $a
}

# Asks for each setting, showing the current value, and saves them to config.txt
function Edit-Settings {
  $oldUrl = $Cfg["STARTUP_URL"]
  Write-Host "Press Enter to keep the value in [brackets], or type a new one."
  Write-Host ""
  while ($true) {
    $url = Read-Value "Page to open in every profile" $Cfg["STARTUP_URL"]
    if ($url -match '^https?://\S+$') { break }
    Write-Host "  Please enter a web address starting with https:// (or http://)"
  }
  while ($true) {
    $count = Read-Value "How many profiles" $Cfg["PROFILE_COUNT"]
    if ($count -match '^\d+$' -and [int]$count -ge 1) { break }
    Write-Host "  Please enter a whole number, 1 or more."
  }
  while ($true) {
    $dMin = Read-Value "Shortest pause between opening profiles, in seconds" $Cfg["DELAY_MIN"]
    $dMax = Read-Value "Longest pause between opening profiles, in seconds" $Cfg["DELAY_MAX"]
    if ($dMin -match '^\d+$' -and $dMax -match '^\d+$' -and [int]$dMin -le [int]$dMax) { break }
    Write-Host "  Please enter whole numbers, with the shortest no longer than the longest."
  }

  try {
    Set-ConfigValue "STARTUP_URL" $url
    Set-ConfigValue "PROFILE_COUNT" ([int]$count)
    Set-ConfigValue "DELAY_MIN" ([int]$dMin)
    Set-ConfigValue "DELAY_MAX" ([int]$dMax)
    # The advanced settings are only asked about if they're wrong, so the menu can always start
    foreach ($k in "INSTALL_TIMEOUT", "MAX_SCREENS") {
      if ($Cfg[$k] -match '^\d+$') { continue }
      $def = @{ INSTALL_TIMEOUT = "90"; MAX_SCREENS = "0" }[$k]
      Write-Host "config.txt has an invalid $k ('$($Cfg[$k])')."
      while ($true) {
        $v = Read-Value "$k (a whole number)" $def
        if ($v -match '^\d+$') { break }
        Write-Host "  Please enter a whole number."
      }
      Set-ConfigValue $k ([int]$v)
    }
  } catch {
    Write-Host "Couldn't save the settings to ${ConfigFile}: $($_.Exception.Message)" -ForegroundColor Red
    return $false
  }
  if (-not (Read-Settings)) { return $false }
  Write-Host ""
  Write-Host "Saved."
  if ($url -ne $oldUrl -and (Get-InstallMode) -eq "policy" -and $SetStartup) {
    Write-Host "Chrome's own startup page was set at step 1. Choose step 1 again to change it too."
  }
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

# One line for each sign that an organisation (work or school) manages this PC.
# Chrome settings that Stagehand installed itself don't count.
function Get-ManagedReasons {
  $why = @()
  try {
    if ((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).PartOfDomain) {
      $why += "it's joined to a company network (domain)"
    }
  } catch {}
  try {
    $ds = (& dsregcmd.exe /status 2>$null) -join "`n"
    if ($ds -match 'AzureAdJoined\s*:\s*YES') { $why += "it's joined to an organisation's Microsoft Entra ID" }
    if ($ds -match 'EnterpriseJoined\s*:\s*YES') { $why += "it's joined to an organisation's network" }
    if ($ds -match 'MdmUrl\s*:\s*https?://') { $why += "it's enrolled in device management (MDM)" }
  } catch {}
  foreach ($k in "HKLM:\SOFTWARE\WOW6432Node\Google\Enrollment", "HKLM:\SOFTWARE\Google\Enrollment") {
    if ((Test-Path $k) -and ((Get-Item $k).GetValue("dmtoken"))) {
      $why += "Chrome is managed by an organisation (Chrome Enterprise)"
      break
    }
  }
  # Stagehand only writes machine-wide (HKLM) policies, so its startup settings can only be there,
  # and only while its extension entry is installed. Every other Chrome policy is the organisation's.
  $ours = Test-PolicyInstalled
  foreach ($root in "HKLM:\SOFTWARE\Policies\Google\Chrome", "HKCU:\SOFTWARE\Policies\Google\Chrome") {
    if (-not (Test-Path $root)) { continue }
    $mine = $ours -and $root.StartsWith("HKLM:")
    $extra = @((Get-Item $root).GetValueNames() | Where-Object { -not ($mine -and $_ -eq "RestoreOnStartup") })
    foreach ($sub in Get-ChildItem $root) {
      $name = $sub.PSChildName
      if ($mine -and $name -eq "RestoreOnStartupURLs") { continue }
      if ($mine -and $name -eq "ExtensionInstallForcelist") {
        $others = @(Get-ListEntries "$root\$name" | Where-Object { -not $_.Value.StartsWith("$ExtId;") })
        if ($others.Count -eq 0) { continue }
      }
      $extra += $name
    }
    if ($extra.Count -gt 0) { $why += "Chrome already has settings from an organisation ($($extra -join ', '))" }
  }
  return $why
}

# How the extension gets into each profile, chosen at step 1:
#   policy = a Chrome policy installs it everywhere (own computer; no clicks)
#   store  = the user clicks "Add to Chrome" in each profile (work or school computer)
# Returns "policy", "store", or "" if step 1 hasn't been done yet.
function Get-InstallMode {
  if (Test-Path $ModeFile) { return ([System.IO.File]::ReadAllText($ModeFile)).Trim() }
  if (Test-PolicyInstalled) { return "policy" }   # set up by an earlier version
  return ""
}

function Set-InstallMode($mode) {
  New-Item -ItemType Directory -Path (Split-Path -Parent $ModeFile) -Force | Out-Null
  [System.IO.File]::WriteAllText($ModeFile, $mode)
}

function Test-NeedStep1 {
  if ((Get-InstallMode) -ne "") { return $false }
  Write-Host "Please choose step 1 first."
  return $true
}

# Removes the startup page Stagehand put in the policy (as recorded when it was set, plus the
# current STARTUP_URL), and the startup setting itself once no startup pages are left.
# Must run as administrator.
function Remove-StartupPolicy {
  $urlKey = "$PolicyRoot\RestoreOnStartupURLs"
  $urls = @()
  if (Test-Path $StartupUrlFile) { $urls += ([System.IO.File]::ReadAllText($StartupUrlFile)).Trim() }
  if ($StartupUrl -ne "") { $urls += $StartupUrl }
  foreach ($u in ($urls | Where-Object { $_ -ne "" } | Select-Object -Unique)) { Remove-ListEntry $urlKey $u $false }
  if (-not (Test-Path $urlKey)) {
    Remove-ItemProperty -Path $PolicyRoot -Name "RestoreOnStartup" -ErrorAction SilentlyContinue
  }
  if (Test-Path $StartupUrlFile) { Remove-Item $StartupUrlFile -Force }
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

  # Replace the startup page Stagehand set last time, rather than adding another one
  Remove-StartupPolicy
  if ($SetStartup -and $StartupUrl -ne "") {
    New-ItemProperty -Path $PolicyRoot -Name "RestoreOnStartup" -PropertyType DWord -Value 4 -Force | Out-Null
    $urlKey = "$PolicyRoot\RestoreOnStartupURLs"
    if (-not (Test-Path $urlKey)) { New-Item -Path $urlKey -Force | Out-Null }
    Add-ListEntry $urlKey $StartupUrl $false
    New-Item -ItemType Directory -Path (Split-Path -Parent $StartupUrlFile) -Force | Out-Null
    [System.IO.File]::WriteAllText($StartupUrlFile, $StartupUrl)
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
  Remove-StartupPolicy
  Write-Host "Policy removed. Restart Chrome; chrome://policy should no longer list these settings."
}

# ---------------------------------------------------------------- profiles

# Opens one profile just long enough for the extension to be installed in it: by the
# policy, or by the user clicking "Add to Chrome" on the Web Store page.
# Returns $true if the extension is there afterwards, $false if it never appeared.
function Install-ExtensionIn($p) {
  $extDir = Join-Path $UserData "$p\Extensions\$ExtId"
  if (-not (Test-Path $extDir)) {
    $url = "about:blank"
    $timeout = $InstallTimeout
    if ((Get-InstallMode) -eq "store") {
      $url = $StoreUrl
      $timeout = $StoreTimeout
      Write-Host "    In the Chrome window that opens, click 'Add to Chrome', then 'Add extension'."
    }
    Start-Process $ChromeExe -ArgumentList @("--profile-directory=`"$p`"", $url)
    $waited = 0
    while (-not (Test-Path $extDir) -and $waited -lt $timeout) {
      Start-Sleep -Seconds 2
      $waited += 2
    }
    if (Test-Path $extDir) { Start-Sleep -Seconds 4 }
    Stop-Chrome
  }
  return (Test-Path $extDir)
}

# True if the master profile has Lightning Autofill set up (anything bigger than a fresh install)
function Test-MasterSetUp {
  return ((Get-SettingsKB (Join-Path $UserData "$MasterProfile\Local Extension Settings\$ExtId")) -ge 8)
}

# True if the master's Lightning Autofill settings changed after the last copy (step 3)
function Test-MasterChangedSinceCopy {
  if (-not (Test-Path $CopyStamp)) { return $false }
  $since = (Get-Item $CopyStamp).LastWriteTime
  $dir = Join-Path $UserData "$MasterProfile\Local Extension Settings\$ExtId"
  if (-not (Test-Path $dir)) { return $false }
  return [bool](Get-ChildItem $dir -Recurse -File | Where-Object { $_.LastWriteTime -gt $since } | Select-Object -First 1)
}

function Open-MasterProfile {
  if (Test-NeedStep1) { return }
  $chromeArgs = @("--profile-directory=`"$MasterProfile`"", "--new-window")
  if (Test-MasterSetUp) {
    Write-Host "Opening the master profile, so you can change the $ExtName set-up."
    Write-Host ""
    Write-Host "When Chrome opens:"
    Write-Host "  - Open $ExtName's Options (right-click the lightning icon > Options)."
    Write-Host "  - Make your changes. For new rules: Sync tab > Remote Import > Import,"
    Write-Host "    then click Save on the Form Fields tab."
    Write-Host "  - Close Chrome completely."
    Write-Host "Then come back here and choose step 3 to copy the changes into every profile."
    Start-Process $ChromeExe -ArgumentList $chromeArgs
    return
  }
  Write-Host "Opening the master profile."
  Write-Host "This is a separate Chrome profile just for setting up $ExtName by hand."
  Write-Host ""
  Write-Host "When Chrome opens:"
  Write-Host "  - If it asks you to sign in or turn on sync, choose 'Don't sign in'."
  if ((Get-InstallMode) -eq "store") {
    Write-Host "  - Click 'Add to Chrome', then 'Add extension', to install $ExtName."
    $chromeArgs += $StoreUrl
  } else {
    Write-Host "  - Wait for $ExtName to install itself (up to a minute the first time)."
  }
  Write-Host "  - Follow your Autofill instructions to set up $ExtName."
  Write-Host "  - When you've finished and clicked Save, close Chrome completely."
  Write-Host "Then come back here and choose step 3."
  Start-Process $ChromeExe -ArgumentList $chromeArgs
}

function Copy-Master {
  if (Test-NeedStep1) { return }
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
      Write-Host "    WARNING: the extension didn't appear." -ForegroundColor Yellow
      if ($tried -eq 1) {
        Write-Host ""
        if ((Get-InstallMode) -eq "store") {
          Write-Host "Did you click 'Add to Chrome' and then 'Add extension'? If the Web Store said the"
          Write-Host "extension is blocked, your organisation doesn't allow it on this computer."
        } else {
          Write-Host "That usually means the one-time setup (step 1) isn't finished, so Chrome isn't"
          Write-Host "installing the extension. Open chrome://policy in Chrome to check, then run step 1 again."
        }
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
  New-Item -ItemType Directory -Path (Split-Path -Parent $CopyStamp) -Force | Out-Null
  [System.IO.File]::WriteAllText($CopyStamp, (Get-Date -Format o))
  Write-Host "Copied the master profile to $copied of $total profiles."
  if (Test-Path $backup) { Write-Host "What was there before is backed up in: $backup" }
  Write-Host ""
  Write-Host "Next, check one copy: open it (step 4 or 5), then in $ExtName's Options look for"
  Write-Host "'Activated' on the Settings tab and your rules on the Form Fields tab."
}

function Show-Status {
  Write-Host "Chrome data folder: $UserData"
  Write-Host "Extension: $ExtName ($ExtId)"
  switch (Get-InstallMode) {
    "store"  { Write-Host "Install mode: Add to Chrome in each profile (no policy)" }
    "policy" { Write-Host "Install mode: Chrome policy installs it everywhere" }
    default  { Write-Host "Install mode: not chosen yet (step 1)" }
  }
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

function Use-StoreMode {
  Set-InstallMode "store"
  Write-Host "OK: nothing on this computer will be changed. Instead, when each profile is created,"
  Write-Host "Chrome opens on $ExtName's Web Store page and you click 'Add to Chrome',"
  Write-Host "then 'Add extension'. That's two clicks per profile, once."
  Write-Host ""
  Write-Host "On a work or school computer, check first that your organisation allows this:"
  Write-Host "its security software may notice Stagehand creating Chrome profiles and moving windows."
}

function Start-OneTimeSetup {
  if ((Get-InstallMode) -eq "") {
    Write-Host "First, a few settings (you can change them later with option 8)."
    if (-not (Edit-Settings)) { return }
    Write-Host ""
  }
  $why = @(Get-ManagedReasons)
  if ($why.Count -gt 0) {
    Write-Host "This looks like a work or school computer:" -ForegroundColor Yellow
    foreach ($w in $why) { Write-Host "  - $w" }
    Write-Host ""
    Write-Host "So I won't change Chrome's settings for the whole computer."
    Use-StoreMode
  } else {
    Write-Host "On your own computer, Stagehand can let Chrome install $ExtName in every"
    Write-Host "profile by itself. It does that with a Chrome setting for the whole computer, so"
    Write-Host "it's not for a computer from work or school."
    Write-Host ""
    if (Read-YesNo "Is this your own personal computer?") {
      Install-Policy
      if (-not (Test-PolicyInstalled)) {
        Write-Host "The policy isn't installed, so I'm stopping here." -ForegroundColor Yellow
        return
      }
      Set-InstallMode "policy"
    } else {
      Write-Host ""
      Use-StoreMode
    }
  }
  Write-Host ""
  Write-Host "One-time setup finished. Next, choose step 2 to open the master profile."
}

# ---------------------------------------------------------------- uninstall

function Remove-Stagehand {
  Write-Host "This removes what Stagehand set up: it deletes the profiles it made and, if you"
  Write-Host "want, takes $ExtName back off this computer."
  Write-Host ""
  if (-not (Remove-ChromeProfiles)) { return }
  if (Test-PolicyInstalled) {
    Write-Host ""
    Write-Host "Chrome is still set to install $ExtName in every profile on this computer"
    Write-Host "(that's why it says 'Managed by your organization')."
    Write-Host "Taking that off also removes $ExtName, and its saved settings, from every"
    Write-Host "profile that's left, including the master profile if you kept it."
    if (-not (Read-YesNo "Take it off now?")) {
      Write-Host "Left in place. Choose this option again whenever you're ready."
      return
    }
    Remove-Policy
    if (Test-PolicyInstalled) { return }
  }
  if (Test-Path $ModeFile) { Remove-Item $ModeFile -Force }
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

# Returns $false if the user cancelled.
function Remove-ChromeProfiles {
  $existing = @($Profiles | Where-Object { $_ -ne "Default" -and (Test-Path (Join-Path $UserData $_)) })
  if ($existing.Count -eq 0 -and -not (Test-Path (Join-Path $UserData $MasterProfile))) {
    Write-Host "None of the profiles exist, so there's nothing to delete."
    return $true
  }

  $list = @($existing)
  if (Test-Path (Join-Path $UserData $MasterProfile)) {
    Write-Host "Your master profile ($MasterProfile) is where $ExtName is set up by hand."
    Write-Host "Keeping it means you can copy it into new profiles again later."
    if (Read-YesNo "Delete the master profile too?") { $list += $MasterProfile }
  }
  if ($list.Count -eq 0) { Write-Host "Nothing left to delete."; return $true }

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
  if ($typed -cne "DELETE") { Write-Host "Cancelled."; return $false }

  if (-not (Confirm-ChromeClosed)) { return $false }

  # Delete the folders first, then take only the ones that really went out of Chrome's list,
  # so a profile that couldn't be deleted stays listed in Chrome
  $gone = @()
  try {
    Add-Type -AssemblyName Microsoft.VisualBasic
  } catch {
    Write-Host "Couldn't load what's needed to use the Recycle Bin, so nothing was deleted." -ForegroundColor Yellow
    return $false
  }
  foreach ($p in $list) {
    $dir = Join-Path $UserData $p
    try {
      [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
        $dir,
        [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
        [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
      Write-Host "${p}: deleted"
      $gone += $p
    } catch {
      Write-Host "${p}: couldn't be deleted, so it was left as it was ($($_.Exception.Message))" -ForegroundColor Yellow
    }
  }
  Write-Host ""
  Write-Host "Deleted $($gone.Count) profile(s). Empty the Recycle Bin to free the space."
  if ($gone.Count -gt 0 -and -not (Update-LocalState $gone)) {
    Write-Host "I couldn't update Chrome's list of profiles, so it may still show the deleted ones."
  }
  Write-Host "If Chrome still shows a deleted profile in its profile picker, click the three dots on"
  Write-Host "that card and choose Delete."
  return ($gone.Count -eq $list.Count)
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
    "remove"          { Remove-Stagehand }
    "settings"        { [void](Edit-Settings) }
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
  $chosen = ((Get-InstallMode) -ne "")
  $setUp  = (Test-MasterSetUp)
  $copied = $true
  foreach ($p in $Profiles) {
    if ((Get-SettingsKB (Join-Path $UserData "$p\Local Extension Settings\$ExtId")) -lt 8) { $copied = $false; break }
  }
  if (Test-MasterChangedSinceCopy) { $copied = $false }
  return @($chosen, $setUp, $copied)
}

function Show-Menu {
  while ($true) {
    Clear-Host
    Show-Banner
    $done   = Get-Progress
    $labels = @(
      "Choose how to install $ExtName",
      "Set up $ExtName in the master profile",
      "Copy the master into Profile 1 - Profile $ProfileCount"
    )
    if ($done[1]) { $labels[1] = "Open the master profile to change the Autofill set-up" }
    if (Test-MasterChangedSinceCopy) { $labels[2] += " (the master has changed)" }
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
    Write-Host "      7) Finished with the sale? Remove Stagehand"
    Write-Host "      8) Change settings (page, number of profiles, pauses)"
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
      "7" { Invoke-Action "remove" }
      "8" { Invoke-Action "settings" }
      "Q" { return }
      default { Write-Host "Please choose 1-8 or Q." }
    }
    Write-Host ""
    Read-Host "Press Enter to return to the menu" | Out-Null
  }
}

# ---------------------------------------------------------------- updates

function Get-WebText($url) {
  $r = Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 5
  if ($r.Content -is [byte[]]) { return [System.Text.Encoding]::ASCII.GetString($r.Content).Trim() }
  return ([string]$r.Content).Trim()
}

# Copies a folder's contents over another, file by file (Copy-Item nests folders that already exist)
function Copy-Tree($from, $to, $skip) {
  foreach ($item in Get-ChildItem -LiteralPath $from -Force) {
    if ($skip -contains $item.Name) { continue }
    $target = Join-Path $to $item.Name
    if ($item.PSIsContainer) {
      New-Item -ItemType Directory -Path $target -Force | Out-Null
      Copy-Tree $item.FullName $target @()
    } else {
      Copy-Item -LiteralPath $item.FullName -Destination $target -Force
    }
  }
}

# Deletes whatever is in $installed but not in $new (files a release no longer has),
# leaving the names in $skip alone
function Remove-Extra($installed, $new, $skip) {
  foreach ($item in Get-ChildItem -LiteralPath $installed -Force) {
    if ($skip -contains $item.Name) { continue }
    $counterpart = Join-Path $new $item.Name
    if (-not (Test-Path -LiteralPath $counterpart)) {
      Remove-Item -LiteralPath $item.FullName -Recurse -Force
    } elseif ($item.PSIsContainer) {
      Remove-Extra $item.FullName $counterpart @()
    }
  }
}

# Offers to update to the latest release. Returns $true if it updated, so the menu can restart.
# Only installed copies have a VERSION file, so a git checkout never updates itself.
# Quiet when offline.
function Update-Stagehand {
  if ($env:STAGEHAND_NO_UPDATE) { return $false }
  $versionFile = Join-Path $RepoDir "VERSION"
  if (-not (Test-Path $versionFile)) { return $false }
  $here = ([System.IO.File]::ReadAllText($versionFile)).Trim()
  $ProgressPreference = "SilentlyContinue"   # the progress bar makes downloads much slower
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $latest = Get-WebText "$ReleasesUrl/VERSION"
    if ($latest -notmatch '^\d+\.\d+\.\d+$' -or $here -notmatch '^\d+\.\d+\.\d+$') { return $false }
    if ([version]$latest -le [version]$here) { return $false }
  } catch {
    return $false
  }

  Write-Host "A new version of Stagehand is available ($here -> $latest)."
  Write-Host "Your settings and backups are kept."
  if ((Read-Host "Update now? [Y/n]") -match '^(n|no)$') { return $false }
  $tmp = Join-Path $env:TEMP ("stagehand-" + [guid]::NewGuid())
  try {
    New-Item -ItemType Directory -Path $tmp | Out-Null
    $zip = Join-Path $tmp "stagehand.zip"
    Invoke-WebRequest "$ReleasesUrl/stagehand.zip" -UseBasicParsing -TimeoutSec 120 -OutFile $zip
    Expand-Archive -LiteralPath $zip -DestinationPath $tmp
    $src = Join-Path $tmp "stagehand"
    if (-not (Test-Path (Join-Path $src "scripts\windows.ps1"))) { throw "the download didn't contain the expected files" }
    $skip = @("generated")
    if (Test-Path $ConfigFile) { $skip += "config.txt" }
    Copy-Tree $src $RepoDir $skip
    Remove-Extra $RepoDir $src @("generated", "config.txt")
    Write-Host "Updated to Stagehand $latest (your config.txt was kept)."
    Write-Host ""
    return $true
  } catch {
    Write-Host "The update didn't work ($($_.Exception.Message)), so carrying on with $here." -ForegroundColor Yellow
    Read-Host "Press Enter to continue" | Out-Null
    return $false
  } finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
}

# ---------------------------------------------------------------- main

if ($Action -eq "menu" -and (Update-Stagehand)) {
  # start again with the new files; PowerShell has already read this copy of the script
  $env:STAGEHAND_NO_UPDATE = "1"
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath
  exit $LASTEXITCODE
}

if (-not (Read-Settings)) {
  Write-Host ""
  Write-Host "Let's fix the settings."
  Write-Host ""
  if (-not (Edit-Settings)) {
    Read-Host "Press Enter to close" | Out-Null
    exit 1
  }
}

$ChromeExe = Get-ChromeExe
if (-not $ChromeExe) {
  Write-Host "Google Chrome wasn't found. Please install it first." -ForegroundColor Red
  Read-Host "Press Enter to close" | Out-Null
  exit 1
}

if ($Action -eq "menu") { Show-Menu } else { Invoke-Action $Action }

if ($PauseAtEnd) { Read-Host "Press Enter to close this window" | Out-Null }
