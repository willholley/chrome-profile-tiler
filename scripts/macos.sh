#!/bin/bash
# Chrome Profile Tiler - macOS
# Written for bash 3.2, the version that ships with macOS.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${CONFIG_FILE:-$REPO_DIR/config.txt}"
CHROME_DIR="${CHROME_DATA_DIR:-$HOME/Library/Application Support/Google/Chrome}"
POLICY_ID="com.local.chrome-profile-tiler"

# ---- defaults (config.txt overrides these) ----
EXTENSION_ID="nlmmgnhgdeffjkdckmikfpnddkbbfkkk"
STARTUP_URL=""
SET_STARTUP_PAGE="yes"
PROFILE_COUNT=12
SOURCE_PROFILE="Profile 1"
COPY_TO="ALL"
DELAY_MIN=45
DELAY_MAX=75
INSTALL_TIMEOUT=90
MAX_SCREENS=0

PROFILES=()
SCREENS=()
BOUNDS=()

# ---------------------------------------------------------------- helpers

say() { printf '%s\n' "$*"; }

pause() { read -r -p "Press Enter to continue... " _; }

ask_yes_no() {
  local a
  read -r -p "$1 [y/N] " a
  case "$a" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

chrome_installed() {
  [ -d "/Applications/Google Chrome.app" ] || [ -d "$HOME/Applications/Google Chrome.app" ]
}

chrome_running() { pgrep -x "Google Chrome" >/dev/null 2>&1; }

quit_chrome() {
  chrome_running || return 0
  osascript -e 'tell application "Google Chrome" to quit' >/dev/null 2>&1
  local i
  for i in $(seq 1 20); do
    chrome_running || return 0
    sleep 0.5
  done
  pkill -x "Google Chrome" 2>/dev/null
  sleep 2
}

ensure_chrome_closed() {
  chrome_running || return 0
  say "Chrome is running. It needs to be closed for this step."
  if ask_yes_no "Close all Chrome windows now?"; then
    quit_chrome
    return 0
  fi
  say "Cancelled."
  return 1
}

# ---------------------------------------------------------------- config

load_config() {
  if [ ! -f "$CONFIG_FILE" ]; then
    say "Could not find config.txt at: $CONFIG_FILE"
    return 1
  fi
  local line key val
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    line="$(trim "$line")"
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    key="$(trim "${line%%=*}")"
    val="$(trim "${line#*=}")"
    case "$key" in
      EXTENSION_ID|STARTUP_URL|SET_STARTUP_PAGE|PROFILE_COUNT|SOURCE_PROFILE|COPY_TO|DELAY_MIN|DELAY_MAX|INSTALL_TIMEOUT|MAX_SCREENS)
        printf -v "$key" '%s' "$val" ;;
    esac
  done < "$CONFIG_FILE"
  return 0
}

validate_config() {
  local bad=0 k v
  if ! [[ "$EXTENSION_ID" =~ ^[a-p]{32}$ ]]; then
    say "config.txt: EXTENSION_ID should be 32 letters (a-p). Copy it from the Chrome Web Store URL."
    bad=1
  fi
  for k in PROFILE_COUNT DELAY_MIN DELAY_MAX INSTALL_TIMEOUT MAX_SCREENS; do
    eval "v=\$$k"
    if ! [[ "$v" =~ ^[0-9]+$ ]]; then
      say "config.txt: $k must be a whole number."
      bad=1
    fi
  done
  if [ "$bad" -eq 0 ]; then
    [ "$PROFILE_COUNT" -lt 1 ] && { say "config.txt: PROFILE_COUNT must be at least 1."; bad=1; }
    [ "$DELAY_MIN" -gt "$DELAY_MAX" ] && { say "config.txt: DELAY_MIN can't be bigger than DELAY_MAX."; bad=1; }
  fi
  if ! [[ "$SOURCE_PROFILE" =~ ^(Default|Profile\ [0-9]+)$ ]]; then
    say "config.txt: SOURCE_PROFILE should look like 'Profile 2' or 'Default'."
    bad=1
  fi
  [ "$bad" -ne 0 ] && return 1

  PROFILES=()
  local n
  for n in $(seq 1 "$PROFILE_COUNT"); do PROFILES+=("Profile $n"); done
  return 0
}

# ---------------------------------------------------------------- policy

install_policy() {
  local out_dir="$REPO_DIR/generated"
  local out="$out_dir/Chrome-Profile-Tiler-Policy.mobileconfig"
  mkdir -p "$out_dir"

  local startup=""
  if [ "$SET_STARTUP_PAGE" = "yes" ] && [ -n "$STARTUP_URL" ]; then
    startup="      <key>RestoreOnStartup</key><integer>4</integer>
      <key>RestoreOnStartupURLs</key>
      <array><string>$(xml_escape "$STARTUP_URL")</string></array>"
  fi

  cat > "$out" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>PayloadType</key><string>Configuration</string>
  <key>PayloadVersion</key><integer>1</integer>
  <key>PayloadIdentifier</key><string>$POLICY_ID</string>
  <key>PayloadUUID</key><string>$(uuidgen)</string>
  <key>PayloadDisplayName</key><string>Chrome Profile Tiler Policy</string>
  <key>PayloadDescription</key><string>Installs one Chrome extension and sets a startup page in every Chrome profile.</string>
  <key>PayloadContent</key>
  <array>
    <dict>
      <key>PayloadType</key><string>com.google.Chrome</string>
      <key>PayloadVersion</key><integer>1</integer>
      <key>PayloadIdentifier</key><string>$POLICY_ID.chrome</string>
      <key>PayloadUUID</key><string>$(uuidgen)</string>
      <key>ExtensionInstallForcelist</key>
      <array>
        <string>$EXTENSION_ID;https://clients2.google.com/service/update2/crx</string>
      </array>
$startup
    </dict>
  </array>
</dict>
</plist>
EOF

  say "I've created a settings profile and will open it now."
  say ""
  say "To finish, you need to approve it in System Settings:"
  say "  1. Open System Settings and search for 'Profiles'"
  say "     (on some macOS versions: Privacy & Security > Profiles,"
  say "      on others: General > Device Management)."
  say "  2. Double-click 'Chrome Profile Tiler Policy' and click Install."
  say "  3. Enter your Mac password if asked."
  say ""
  open "$out"
  read -r -p "Press Enter once you've installed it... " _
  say ""
  say "You can confirm it worked later by opening chrome://policy in Chrome."
}

remove_policy() {
  say "Removing the settings profile (you'll be asked for your Mac password)..."
  if sudo profiles remove -identifier "$POLICY_ID" 2>/dev/null; then
    say "Removed. Restart Chrome; chrome://policy should no longer list these settings."
  else
    say "I couldn't remove it automatically. To remove it by hand:"
    say "  System Settings > search 'Profiles' > select 'Chrome Profile Tiler Policy' > click the minus (-) button."
  fi
}

# ---------------------------------------------------------------- profiles

create_profiles() {
  ensure_chrome_closed || return 1
  say "Opening each profile once so Chrome installs the extension."
  say "(Profiles that don't exist yet are created.)"
  local total=${#PROFILES[@]} i=0 p waited ext_dir
  local missing=0
  for p in "${PROFILES[@]}"; do
    i=$((i + 1))
    ext_dir="$CHROME_DIR/$p/Extensions/$EXTENSION_ID"
    say "[$(date +%H:%M:%S)] ($i/$total) $p"
    open -na "Google Chrome" --args --profile-directory="$p" about:blank
    waited=0
    while [ ! -d "$ext_dir" ] && [ "$waited" -lt "$INSTALL_TIMEOUT" ]; do
      sleep 2
      waited=$((waited + 2))
    done
    if [ -d "$ext_dir" ]; then
      sleep 4
      say "    extension installed"
    else
      say "    WARNING: the extension didn't appear within ${INSTALL_TIMEOUT}s."
      missing=$((missing + 1))
    fi
    quit_chrome
  done
  if [ "$missing" -gt 0 ]; then
    say ""
    say "$missing profile(s) did not get the extension. Check that the settings profile"
    say "is installed (open chrome://policy in Chrome), then run this step again."
    return 1
  fi
  return 0
}

open_primary() {
  say "Opening $SOURCE_PROFILE."
  say "Set up the extension there (its options/settings page), then close Chrome"
  say "completely and choose 'Copy primary settings' from the menu."
  open -na "Google Chrome" --args --profile-directory="$SOURCE_PROFILE" chrome://extensions
}

# Prints the profiles that should receive settings, one per line
copy_targets() {
  local p x
  if [ -z "$COPY_TO" ] || [ "$COPY_TO" = "ALL" ]; then
    for p in "${PROFILES[@]}"; do
      [ "$p" != "$SOURCE_PROFILE" ] && printf '%s\n' "$p"
    done
  else
    printf '%s\n' "$COPY_TO" | tr ',' '\n' | while IFS= read -r x; do
      x="$(trim "$x")"
      if [ -n "$x" ] && [ "$x" != "$SOURCE_PROFILE" ]; then printf '%s\n' "$x"; fi
    done
  fi
}

copy_settings() {
  local src="$CHROME_DIR/$SOURCE_PROFILE"
  if [ ! -d "$src/Local Extension Settings/$EXTENSION_ID" ]; then
    say "$SOURCE_PROFILE has no saved settings for this extension yet."
    say "Choose 'Open primary profile' from the menu, set the extension up, close Chrome, then try again."
    return 1
  fi

  local targets p a copied=0
  targets=()
  while IFS= read -r p; do
    [ -n "$p" ] && targets+=("$p")
  done < <(copy_targets)
  if [ ${#targets[@]} -eq 0 ]; then
    say "There are no other profiles to copy to (check COPY_TO in config.txt)."
    return 1
  fi
  say "This will REPLACE the extension's saved settings in these profiles"
  say "with the settings from $SOURCE_PROFILE:"
  printf '  - %s\n' "${targets[@]}"
  say "(Whatever is there now is backed up first.)"
  ask_yes_no "Continue?" || { say "Cancelled."; return 1; }
  ensure_chrome_closed || return 1

  local backup="$REPO_DIR/generated/backup-$(date +%Y%m%d-%H%M%S)"
  for p in "${targets[@]}"; do
    if [ ! -d "$CHROME_DIR/$p" ]; then
      say "$p: profile folder doesn't exist yet (run first-time setup) - skipped"
      continue
    fi
    for a in "Local Extension Settings" "Sync Extension Settings"; do
      if [ -d "$src/$a/$EXTENSION_ID" ]; then
        if [ -d "$CHROME_DIR/$p/$a/$EXTENSION_ID" ]; then
          mkdir -p "$backup/$p/$a"
          cp -R "$CHROME_DIR/$p/$a/$EXTENSION_ID" "$backup/$p/$a/"
        fi
        mkdir -p "$CHROME_DIR/$p/$a"
        rm -rf "$CHROME_DIR/$p/$a/$EXTENSION_ID"
        cp -R "$src/$a/$EXTENSION_ID" "$CHROME_DIR/$p/$a/$EXTENSION_ID"
      fi
    done
    say "$p: copied"
    copied=$((copied + 1))
  done

  say ""
  say "Copied settings from $SOURCE_PROFILE to $copied profile(s)."
  [ -d "$backup" ] && say "Previous settings were backed up to: $backup"
  say "If a profile is signed in to a Google account with Chrome sync on, Chrome may"
  say "overwrite the copy. Use the extension's own Export/Import for those."
  return 0
}

show_status() {
  say "Chrome data folder: $CHROME_DIR"
  say "Extension: $EXTENSION_ID"
  if profiles list 2>/dev/null | grep -q "$POLICY_ID"; then
    say "Policy settings profile: installed"
  else
    say "Policy settings profile: not detected here (confirm at chrome://policy in Chrome)"
  fi
  say ""
  printf '%-12s %-11s %s\n' "PROFILE" "EXTENSION" "SAVED SETTINGS"
  local p list inst size d note
  list=("$SOURCE_PROFILE")
  for p in "${PROFILES[@]}"; do
    [ "$p" != "$SOURCE_PROFILE" ] && list+=("$p")
  done
  for p in "${list[@]}"; do
    if [ ! -d "$CHROME_DIR/$p" ]; then
      printf '%-12s %s\n' "$p" "(profile not created yet)"
      continue
    fi
    inst="no"
    [ -d "$CHROME_DIR/$p/Extensions/$EXTENSION_ID" ] && inst="yes"
    d="$CHROME_DIR/$p/Local Extension Settings/$EXTENSION_ID"
    size="none"
    [ -d "$d" ] && size="$(du -sk "$d" | cut -f1) KB"
    note=""
    [ "$p" = "$SOURCE_PROFILE" ] && note="   <- primary"
    printf '%-12s %-11s %s%s\n' "$p" "$inst" "$size" "$note"
  done
  say ""
  say "Tip: a configured profile usually has a much larger 'saved settings' size than a fresh one."
}

first_time_setup() {
  ensure_chrome_closed || return 1
  install_policy
  create_profiles || return 1
  say ""
  say "First-time setup finished. Next:"
  say "  2) Open primary profile - configure the extension there"
  say "  3) Copy primary settings to the other profiles"
  say "  4) Launch all profiles, tiled"
}

# ---------------------------------------------------------------- tiling

# Fills SCREENS with "x y w h" (top-left origin) for every display's usable area
detect_screens() {
  SCREENS=()
  local line
  while IFS= read -r line; do
    [ -n "$line" ] && SCREENS+=("$line")
  done < <(osascript -l JavaScript -e '
    ObjC.import("AppKit");
    var scr = ObjC.unwrap($.NSScreen.screens);
    var H = scr[0].frame.size.height, out = [];
    for (var i = 0; i < scr.length; i++) {
      var v = scr[i].visibleFrame;
      out.push([v.origin.x, H - (v.origin.y + v.size.height), v.size.width, v.size.height]
        .map(Math.round).join(" "));
    }
    out.join("\n")' 2>/dev/null)

  if [ ${#SCREENS[@]} -eq 0 ]; then
    # fallback: primary screen only, leaving room for the menu bar
    local b bx by bw bh
    b="$(osascript -e 'tell application "Finder" to get bounds of window of desktop' 2>/dev/null | tr -d ' ')"
    IFS=, read -r bx by bw bh <<< "$b"
    if [ -n "$bw" ] && [ -n "$bh" ]; then
      SCREENS+=("0 25 $bw $((bh - 25))")
    fi
  fi
}

# $1 = number of windows. Fills BOUNDS with "left top right bottom", one grid per screen
build_bounds() {
  local total=$1 ns=${#SCREENS[@]}
  if [ "$MAX_SCREENS" -gt 0 ] && [ "$MAX_SCREENS" -lt "$ns" ]; then ns=$MAX_SCREENS; fi
  BOUNDS=()
  local base=$((total / ns)) rem=$((total % ns))
  local s cnt SX SY SW SH cols rows cw ch k l t
  for ((s = 0; s < ns; s++)); do
    cnt=$((base + (s < rem ? 1 : 0)))
    [ "$cnt" -eq 0 ] && continue
    read -r SX SY SW SH <<< "${SCREENS[$s]}"
    cols=$(awk -v n="$cnt" 'BEGIN{c=int(sqrt(n)); if (c*c<n) c++; print c}')
    rows=$(((cnt + cols - 1) / cols))
    cw=$((SW / cols))
    ch=$((SH / rows))
    say "Screen $((s + 1)): $cnt windows in a ${cols}x${rows} grid (${cw}x${ch} each)"
    for ((k = 0; k < cnt; k++)); do
      l=$((SX + (k % cols) * cw))
      t=$((SY + (k / cols) * ch))
      BOUNDS+=("$l $t $((l + cw)) $((t + ch))")
    done
  done
}

# IDs of current Chrome windows. Only asks Chrome if it's already running,
# so this never launches the wrong profile by accident.
chrome_ids() {
  chrome_running || return 0
  osascript -e 'tell application "Google Chrome" to get id of every window' 2>/dev/null \
    | tr -d ' ' | tr ',' '\n'
}

# $1 = window IDs that existed before; $2..$5 = left top right bottom
place_new_window() {
  local before="$1" left=$2 top=$3 right=$4 bottom=$5 id pass n
  for n in $(seq 1 30); do
    sleep 0.5
    for id in $(chrome_ids); do
      if ! grep -qx "$id" <<< "$before"; then
        for pass in 1 2; do  # twice: Chrome can re-apply its saved size just after opening
          osascript -e "tell application \"Google Chrome\" to set bounds of (first window whose id is $id) to {$left, $top, $right, $bottom}" >/dev/null 2>&1
          sleep 1
        done
        return 0
      fi
    done
  done
  say "    warning: couldn't find the new window to position"
  return 1
}

launch_tiled() {
  detect_screens
  if [ ${#SCREENS[@]} -eq 0 ]; then
    say "Couldn't read your screen sizes. Windows will open untiled."
  fi
  local total=${#PROFILES[@]}
  if [ ${#SCREENS[@]} -gt 0 ]; then build_bounds "$total"; fi

  # keep the Mac awake until this script finishes
  caffeinate -i -w $$ >/dev/null 2>&1 &

  say "Opening $total profiles with a ${DELAY_MIN}-${DELAY_MAX}s pause between each."
  local i=0 p before left top right bottom delay
  local args
  for p in "${PROFILES[@]}"; do
    i=$((i + 1))
    say "[$(date +%H:%M:%S)] ($i/$total) Launching: $p"
    args=(--profile-directory="$p" --new-window)
    [ -n "$STARTUP_URL" ] && args+=("$STARTUP_URL")
    before="$(chrome_ids)"
    open -na "Google Chrome" --args "${args[@]}"
    if [ ${#BOUNDS[@]} -gt 0 ]; then
      read -r left top right bottom <<< "${BOUNDS[$((i - 1))]}"
      place_new_window "$before" "$left" "$top" "$right" "$bottom"
    fi
    [ "$i" -eq "$total" ] && break
    delay=$((DELAY_MIN + RANDOM % (DELAY_MAX - DELAY_MIN + 1)))
    say "    waiting ${delay}s..."
    sleep "$delay"
  done
  say "Done."
}

# ---------------------------------------------------------------- menu

show_menu() {
  clear
  say "=============================================="
  say "  Chrome Profile Tiler"
  say "=============================================="
  say "  Extension : $EXTENSION_ID"
  say "  Profiles  : Profile 1 - Profile $PROFILE_COUNT   (primary: $SOURCE_PROFILE)"
  say ""
  say "  1) First-time setup (install policy, create profiles, install extension)"
  say "  2) Open primary profile (to configure the extension)"
  say "  3) Copy primary settings to the other profiles"
  say "  4) Launch all profiles, tiled across your screens"
  say "  5) Check status"
  say "  6) Remove the policy (undo step 1)"
  say "  Q) Quit"
  say ""
}

main() {
  load_config || { pause; exit 1; }
  validate_config || { pause; exit 1; }
  if ! chrome_installed; then
    say "Google Chrome wasn't found in /Applications. Please install it first."
    pause
    exit 1
  fi

  local choice
  while true; do
    show_menu
    read -r -p "Choose an option: " choice
    say ""
    case "$choice" in
      1) first_time_setup ;;
      2) open_primary ;;
      3) copy_settings ;;
      4) launch_tiled ;;
      5) show_status ;;
      6) remove_policy ;;
      q|Q) exit 0 ;;
      *) say "Please choose 1-6 or Q." ;;
    esac
    say ""
    pause
  done
}

# run the menu unless this file is being sourced (used for testing)
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main
fi
