#!/bin/bash
# Stagehand - macOS
# Written for bash 3.2, the version that ships with macOS.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${CONFIG_FILE:-$REPO_DIR/config.txt}"
CHROME_DIR="${CHROME_DATA_DIR:-$HOME/Library/Application Support/Google/Chrome}"
POLICY_ID="com.local.chrome-profile-tiler"  # kept from the old name so existing installs can still be removed
OLD_POLICY_IDS="com.local.chrome-policy"     # used by earlier versions; removed along with POLICY_ID
MANAGED_PREFS_DIR="${MANAGED_PREFS_DIR:-/Library/Managed Preferences}"

# How the extension gets into each profile, chosen at step 1:
#   policy = a Chrome policy installs it everywhere (own computer; no clicks)
#   store  = the user clicks "Add to Chrome" in each profile (work or school computer)
MODE_FILE="$REPO_DIR/generated/install-mode"
STORE_URL="https://chromewebstore.google.com/detail/lightning-autofill/nlmmgnhgdeffjkdckmikfpnddkbbfkkk"
STORE_TIMEOUT=300

# Lightning Autofill is the only extension this tool manages
EXTENSION_ID="nlmmgnhgdeffjkdckmikfpnddkbbfkkk"
EXTENSION_NAME="Lightning Autofill"

# The master profile: a dedicated Chrome profile where Lightning Autofill is set up by hand.
# Its settings get copied into Profile 1 ... Profile N.
MASTER_PROFILE="Autofill Master"

# Every merge to main is published as a release with these files attached (see .github/workflows)
RELEASES_URL="${RELEASES_URL:-https://github.com/willholley/stagehand/releases/latest/download}"

# ---- defaults (config.txt overrides these) ----
STARTUP_URL=""
SET_STARTUP_PAGE="yes"
PROFILE_COUNT=12
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

# Total size of the files in a folder, in KB. Uses real file sizes, not disk blocks
# (disk usage rounds every tiny file up to 4 KB, which would hide the difference
# between a fresh and a set-up profile).
dir_kb() {
  local bytes
  bytes="$(find "$1" -type f -exec cat {} + 2>/dev/null | wc -c | tr -d ' ')"
  echo $(( (bytes + 512) / 1024 ))
}

chrome_installed() {
  [ -d "/Applications/Google Chrome.app" ] || [ -d "$HOME/Applications/Google Chrome.app" ]
}

chrome_running() { pgrep -x "Google Chrome" >/dev/null 2>&1; }

# Prints one line for each sign that an organisation (work or school) manages this Mac.
# Chrome settings that Stagehand installed itself don't count, and nor does Screen Time.
managed_reasons() {
  local enrol f extra
  enrol="$(profiles status -type enrollment 2>/dev/null)"
  case "$enrol" in *"MDM enrollment: Yes"*) say "it's enrolled in device management (MDM)" ;; esac
  case "$enrol" in *"Enrolled via DEP: Yes"*) say "it was set up by an organisation (Automated Device Enrollment)" ;; esac
  [ -e "/Library/Application Support/Google/CloudManagement" ] && say "Chrome is managed by an organisation (Chrome Enterprise)"
  for f in "$MANAGED_PREFS_DIR/com.google.Chrome.plist" "$MANAGED_PREFS_DIR/$(id -un)/com.google.Chrome.plist"; do
    [ -f "$f" ] || continue
    extra="$(plutil -convert json -o - "$f" 2>/dev/null | perl -MJSON::PP -e '
      my $ext = shift;
      my $d = eval { local $/; decode_json(<STDIN>) } or do { print "unreadable"; exit };
      my %ours = map { $_ => 1 } qw(ExtensionInstallForcelist RestoreOnStartup RestoreOnStartupURLs PayloadUUID _manualProfile);
      my @extra = grep { !$ours{$_} } sort keys %$d;
      push @extra, "ExtensionInstallForcelist"
        if grep { index($_, "$ext;") != 0 } @{ $d->{ExtensionInstallForcelist} || [] };
      push @extra, "settings from device management" unless $d->{_manualProfile};
      print join(", ", @extra);' "$EXTENSION_ID" 2>/dev/null)"
    [ -n "$extra" ] && say "Chrome already has settings from an organisation ($extra)"
  done
}

policy_installed() {
  local id list
  list="$(profiles list 2>/dev/null)"
  for id in $POLICY_ID $OLD_POLICY_IDS; do
    grep -q "$id" <<< "$list" && return 0
  done
  return 1
}

# Prints policy, store, or nothing if step 1 hasn't been done yet
install_mode() {
  if [ -f "$MODE_FILE" ]; then
    cat "$MODE_FILE"
  elif policy_installed; then
    printf 'policy'    # set up by an earlier version, before the mode was saved
  fi
}

set_install_mode() {
  mkdir -p "$(dirname "$MODE_FILE")"
  printf '%s' "$1" > "$MODE_FILE"
}

need_step_1() {
  [ -n "$(install_mode)" ] && return 1
  say "Please choose step 1 first."
  return 0
}

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
      STARTUP_URL|SET_STARTUP_PAGE|PROFILE_COUNT|DELAY_MIN|DELAY_MAX|INSTALL_TIMEOUT|MAX_SCREENS)
        printf -v "$key" '%s' "$val" ;;
    esac
  done < "$CONFIG_FILE"
  return 0
}

validate_config() {
  local bad=0 k v
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
  [ "$bad" -ne 0 ] && return 1

  PROFILES=()
  local n
  for n in $(seq 1 "$PROFILE_COUNT"); do PROFILES+=("Profile $n"); done
  return 0
}

# ---------------------------------------------------------------- policy

install_policy() {
  local out_dir="$REPO_DIR/generated"
  local out="$out_dir/Stagehand-Policy.mobileconfig"
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
  <key>PayloadDisplayName</key><string>Stagehand Policy</string>
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
  say "  2. Double-click 'Stagehand Policy' and click Install."
  say "  3. Enter your Mac password if asked."
  say ""
  open "$out"
  read -r -p "Press Enter once you've installed it... " _
  say ""
  say "You can confirm it worked later by opening chrome://policy in Chrome."
}

remove_policy() {
  say "Removing the settings profile (you'll be asked for your Mac password)..."
  local id
  for id in $OLD_POLICY_IDS; do
    if profiles list 2>/dev/null | grep -q "$id"; then
      sudo profiles remove -identifier "$id" 2>/dev/null && say "Removed the settings profile from an earlier version ($id)."
    fi
  done
  if sudo profiles remove -identifier "$POLICY_ID" 2>/dev/null; then
    say "Removed. Restart Chrome; chrome://policy should no longer list these settings."
  else
    say "I couldn't remove it automatically. To remove it by hand:"
    say "  System Settings > search 'Profiles' > select 'Stagehand Policy' > click the minus (-) button."
    say "  (Earlier versions called it 'Chrome Profile Tiler Policy' or 'Chrome Policy'.)"
  fi
}

# ---------------------------------------------------------------- profiles

# Opens one profile just long enough for the extension to be installed in it: by the
# policy, or by the user clicking "Add to Chrome" on the Web Store page.
# Returns 0 if the extension is there afterwards, 1 if it never appeared.
install_extension_in() {
  local p="$1" ext_dir waited=0 url="about:blank" timeout="$INSTALL_TIMEOUT"
  ext_dir="$CHROME_DIR/$p/Extensions/$EXTENSION_ID"
  if [ ! -d "$ext_dir" ]; then
    if [ "$(install_mode)" = "store" ]; then
      url="$STORE_URL"
      timeout="$STORE_TIMEOUT"
      say "    In the Chrome window that opens, click 'Add to Chrome', then 'Add extension'."
    fi
    open -na "Google Chrome" --args --profile-directory="$p" "$url"
    while [ ! -d "$ext_dir" ] && [ "$waited" -lt "$timeout" ]; do
      sleep 2
      waited=$((waited + 2))
    done
    [ -d "$ext_dir" ] && sleep 4
    quit_chrome
  fi
  [ -d "$ext_dir" ]
}

open_master() {
  need_step_1 && return 1
  local args
  args=(--profile-directory="$MASTER_PROFILE" --new-window)
  say "Opening the master profile."
  say "This is a separate Chrome profile just for setting up $EXTENSION_NAME by hand."
  say ""
  say "When Chrome opens:"
  say "  - If it asks you to sign in or turn on sync, choose 'Don't sign in'."
  if [ "$(install_mode)" = "store" ]; then
    say "  - Click 'Add to Chrome', then 'Add extension', to install $EXTENSION_NAME."
    args+=("$STORE_URL")
  else
    say "  - Wait for $EXTENSION_NAME to install itself (up to a minute the first time)."
  fi
  say "  - Follow your Autofill instructions to set up $EXTENSION_NAME."
  say "  - When you've finished and clicked Save, close Chrome completely (Cmd+Q)."
  say "Then come back here and choose step 3."
  open -na "Google Chrome" --args "${args[@]}"
}

copy_master() {
  need_step_1 && return 1
  local src="$CHROME_DIR/$MASTER_PROFILE"
  local src_local="$src/Local Extension Settings/$EXTENSION_ID"
  if [ ! -d "$src_local" ]; then
    say "The master profile has no $EXTENSION_NAME settings yet."
    say "Choose step 2, set up $EXTENSION_NAME there and click Save, close Chrome,"
    say "then come back to step 3."
    return 1
  fi
  local kb
  kb="$(dir_kb "$src_local")"
  if [ "$kb" -lt 8 ]; then
    say "The master profile's $EXTENSION_NAME looks almost empty (${kb} KB of settings)."
    say "Did you activate it, import the rules and click Save? A set-up profile is usually much bigger."
    ask_yes_no "Copy it anyway?" || { say "Cancelled."; return 1; }
  fi

  say "This copies the master profile's $EXTENSION_NAME settings (key, rules and options) into"
  say "Profile 1 - Profile $PROFILE_COUNT, creating any of those profiles that don't exist yet."
  say "Anything $EXTENSION_NAME has stored in them is replaced (it's backed up first)."
  ask_yes_no "Continue?" || { say "Cancelled."; return 1; }
  ensure_chrome_closed || return 1

  # 1. make sure every profile exists and has the extension installed
  local p i=0 total=${#PROFILES[@]} tried=0
  for p in "${PROFILES[@]}"; do
    i=$((i + 1))
    [ -d "$CHROME_DIR/$p/Extensions/$EXTENSION_ID" ] && continue
    tried=$((tried + 1))
    say "[$(date +%H:%M:%S)] ($i/$total) $p: creating it and installing the extension..."
    if install_extension_in "$p"; then
      say "    done"
    else
      say "    WARNING: the extension didn't appear."
      if [ "$tried" -eq 1 ]; then
        say ""
        if [ "$(install_mode)" = "store" ]; then
          say "Did you click 'Add to Chrome' and then 'Add extension'? If the Web Store said the"
          say "extension is blocked, your organisation doesn't allow it on this computer."
        else
          say "That usually means the one-time setup (step 1) isn't finished, so Chrome isn't"
          say "installing the extension. Open chrome://policy in Chrome to check, then run step 1 again."
        fi
        return 1
      fi
    fi
  done

  # 2. copy the master's settings into each profile
  local a copied=0 backup
  backup="$REPO_DIR/generated/backup-$(date +%Y%m%d-%H%M%S)"
  for p in "${PROFILES[@]}"; do
    if [ ! -d "$CHROME_DIR/$p/Extensions/$EXTENSION_ID" ]; then
      say "$p: skipped (the extension isn't installed there)"
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
  say "Copied the master profile to $copied of $total profiles."
  [ -d "$backup" ] && say "What was there before is backed up in: $backup"
  say ""
  say "Next, check one copy: open it (step 4 or 5), then in $EXTENSION_NAME's Options look for"
  say "'Activated' on the Settings tab and your rules on the Form Fields tab."
  return 0
}

show_status() {
  say "Chrome data folder: $CHROME_DIR"
  say "Extension: $EXTENSION_NAME ($EXTENSION_ID)"
  case "$(install_mode)" in
    store)  say "Install mode: Add to Chrome in each profile (no policy)" ;;
    policy) say "Install mode: Chrome policy installs it everywhere" ;;
    *)      say "Install mode: not chosen yet (step 1)" ;;
  esac
  if policy_installed; then
    say "Policy settings profile: installed"
  else
    say "Policy settings profile: not detected here (confirm at chrome://policy in Chrome)"
  fi
  say ""
  printf '%-18s %-11s %s\n' "PROFILE" "EXTENSION" "SAVED SETTINGS"
  local p list inst size d note
  list=("$MASTER_PROFILE")
  for p in "${PROFILES[@]}"; do list+=("$p"); done
  for p in "${list[@]}"; do
    note=""
    [ "$p" = "$MASTER_PROFILE" ] && note="   <- master"
    if [ ! -d "$CHROME_DIR/$p" ]; then
      printf '%-18s %s%s\n' "$p" "(not created yet)" "$note"
      continue
    fi
    inst="no"
    [ -d "$CHROME_DIR/$p/Extensions/$EXTENSION_ID" ] && inst="yes"
    d="$CHROME_DIR/$p/Local Extension Settings/$EXTENSION_ID"
    size="none"
    [ -d "$d" ] && size="$(dir_kb "$d") KB"
    printf '%-18s %-11s %s%s\n' "$p" "$inst" "$size" "$note"
  done
  say ""
  say "A profile that has been set up usually shows a much bigger 'saved settings' size than a"
  say "fresh one. After step 3, every copy should be close to the master's size."
}

use_store_mode() {
  set_install_mode store
  say "OK: nothing on this computer will be changed. Instead, when each profile is created,"
  say "Chrome opens on $EXTENSION_NAME's Web Store page and you click 'Add to Chrome',"
  say "then 'Add extension'. That's two clicks per profile, once."
  say ""
  say "On a work or school computer, check first that your organisation allows this:"
  say "its security software may notice Stagehand creating Chrome profiles and moving windows."
}

one_time_setup() {
  local why
  why="$(managed_reasons)"
  if [ -n "$why" ]; then
    say "This looks like a work or school computer:"
    printf '%s\n' "$why" | sed 's/^/  - /'
    say ""
    say "So I won't change Chrome's settings for the whole computer."
    use_store_mode
  else
    say "On your own computer, Stagehand can let Chrome install $EXTENSION_NAME in every"
    say "profile by itself. It does that with a Chrome setting for the whole computer, so"
    say "it's not for a computer from work or school."
    say ""
    if ask_yes_no "Is this your own personal computer?"; then
      ensure_chrome_closed || return 1
      install_policy
      set_install_mode policy
    else
      say ""
      use_store_mode
    fi
  fi
  say ""
  say "One-time setup finished. Next, choose step 2 to open the master profile."
}

# ---------------------------------------------------------------- uninstall

remove_stagehand() {
  say "This removes what Stagehand set up: it deletes the profiles it made and, if you"
  say "want, takes $EXTENSION_NAME back off this computer."
  say ""
  delete_profiles || return 1
  if policy_installed; then
    say ""
    say "Chrome is still set to install $EXTENSION_NAME in every profile on this computer"
    say "(that's why it says 'Managed by your organization')."
    say "Taking that off also removes $EXTENSION_NAME, and its saved settings, from every"
    say "profile that's left, including the master profile if you kept it."
    if ask_yes_no "Take it off now?"; then
      remove_policy
    else
      say "Left in place. Choose this option again whenever you're ready."
      return 0
    fi
  fi
  rm -f "$MODE_FILE"
}

# Removes the given profile folders from Chrome's profile list (the "Local State" file).
# Chrome must be closed. Keeps a backup copy and puts it back if anything goes wrong.
tidy_local_state() {
  local ls="$CHROME_DIR/Local State"
  [ -f "$ls" ] || return 0
  command -v perl >/dev/null 2>&1 || return 1
  mkdir -p "$REPO_DIR/generated"
  local bk="$REPO_DIR/generated/Local State.backup-$(date +%Y%m%d-%H%M%S)"
  cp "$ls" "$bk" || return 1
  if perl - "$ls" "$@" 2>/dev/null <<'PERL'
use strict; use warnings; use JSON::PP;
my ($path, @drop) = @ARGV;
my %drop = map { $_ => 1 } @drop;
open my $in, '<:raw', $path or die "read: $!";
my $txt = do { local $/; <$in> };
close $in;
my $json = JSON::PP->new->utf8->allow_nonref;
my $d = $json->decode($txt);
my $p = (ref $d eq 'HASH') ? $d->{profile} : undef;
if (ref $p eq 'HASH') {
  if (ref $p->{info_cache} eq 'HASH') {
    delete $p->{info_cache}{$_} for grep { $drop{$_} } keys %{ $p->{info_cache} };
  }
  for my $k (qw(profiles_order last_active_profiles)) {
    $p->{$k} = [ grep { !$drop{$_} } @{ $p->{$k} } ] if ref $p->{$k} eq 'ARRAY';
  }
  $p->{last_used} = 'Default'
    if defined $p->{last_used} && !ref $p->{last_used} && $drop{ $p->{last_used} };
}
my $out = $json->encode($d);
$json->decode($out);   # must parse again before anything is overwritten
open my $o, '>:raw', "$path.tmp" or die "write: $!";
print $o $out;
close $o or die "close: $!";
rename "$path.tmp", $path or die "rename: $!";
PERL
  then
    return 0
  else
    cp "$bk" "$ls" 2>/dev/null
    return 1
  fi
}

delete_profiles() {
  local p existing list typed trash stamp moved=0
  existing=()
  for p in "${PROFILES[@]}"; do
    [ "$p" = "Default" ] && continue      # the Default profile is never touched
    [ -d "$CHROME_DIR/$p" ] && existing+=("$p")
  done
  if [ ${#existing[@]} -eq 0 ] && [ ! -d "$CHROME_DIR/$MASTER_PROFILE" ]; then
    say "None of the profiles exist, so there's nothing to delete."
    return 0
  fi

  list=("${existing[@]}")
  if [ -d "$CHROME_DIR/$MASTER_PROFILE" ]; then
    say "Your master profile ($MASTER_PROFILE) is where $EXTENSION_NAME is set up by hand."
    say "Keeping it means you can copy it into new profiles again later."
    ask_yes_no "Delete the master profile too?" && list+=("$MASTER_PROFILE")
  fi
  if [ ${#list[@]} -eq 0 ]; then
    say "Nothing left to delete."
    return 0
  fi

  say ""
  say "These profiles will be DELETED:"
  printf '  - %s\n' "${list[@]}"
  say ""
  say "Everything in them goes: browsing history, bookmarks, saved passwords, cookies and"
  say "any accounts signed in there. Your Default profile is never touched."
  say "The folders are moved to the Trash, so you can still get them back until you empty it."
  say ""
  read -r -p "Type DELETE (in capitals) to continue: " typed
  if [ "$typed" != "DELETE" ]; then say "Cancelled."; return 1; fi

  ensure_chrome_closed || return 1

  if ! tidy_local_state "${list[@]}"; then
    say "I couldn't tidy Chrome's list of profiles (nothing was changed there)."
    ask_yes_no "Delete the folders anyway? Chrome may then show empty leftover entries." || { say "Cancelled."; return 1; }
  fi

  trash="$HOME/.Trash"
  stamp="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$trash"
  for p in "${list[@]}"; do
    if mv "$CHROME_DIR/$p" "$trash/Chrome $p $stamp"; then
      say "$p: moved to the Trash"
      moved=$((moved + 1))
    else
      say "$p: couldn't be moved"
    fi
  done
  say ""
  say "Deleted $moved profile(s). Empty the Trash to free the space."
  say "If Chrome still shows a deleted profile in its profile picker, click the three dots on"
  say "that card and choose Delete."
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

# Waits $1 seconds, counting down on a single line
countdown() {
  local s
  for ((s = $1; s > 0; s--)); do
    printf '\r    next window in %3ds ' "$s"
    sleep 1
  done
  printf '\r    next window in   0s\n'
}

launch_tiled() {
  local dmin=$DELAY_MIN dmax=$DELAY_MAX
  if [ "$1" = "fast" ]; then dmin=1; dmax=1; fi

  local p missing=()
  for p in "${PROFILES[@]}"; do
    [ -d "$CHROME_DIR/$p" ] || missing+=("$p")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    say "These profiles don't exist yet: ${missing[*]}"
    say "Run step 3 first; it creates them and copies the master profile into them."
    return 1
  fi

  detect_screens
  if [ ${#SCREENS[@]} -eq 0 ]; then
    say "Couldn't read your screen sizes. Windows will open untiled."
  fi
  local total=${#PROFILES[@]}
  if [ ${#SCREENS[@]} -gt 0 ]; then build_bounds "$total"; fi

  # keep the Mac awake until this script finishes
  caffeinate -i -w $$ >/dev/null 2>&1 &

  if [ "$dmin" -eq "$dmax" ]; then
    say "Opening $total profiles with a ${dmin}s pause between each."
  else
    say "Opening $total profiles with a ${dmin}-${dmax}s pause between each."
  fi
  local i=0 before left top right bottom delay
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
    delay=$((dmin + RANDOM % (dmax - dmin + 1)))
    countdown "$delay"
  done
  say "Done."
}

# ---------------------------------------------------------------- menu

show_banner() {
  cat <<'EOF'

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
EOF
  say "  =============================================="
  say "         Stagehand  -  $EXTENSION_NAME"
  say "  =============================================="
}

# Sets DONE_1, DONE_2, DONE_3 to 1 for each setup step that looks finished
check_progress() {
  local m="$CHROME_DIR/$MASTER_PROFILE" d p
  DONE_1=0; DONE_2=0; DONE_3=1
  [ -n "$(install_mode)" ] && DONE_1=1
  d="$m/Local Extension Settings/$EXTENSION_ID"
  [ -d "$d" ] && [ "$(dir_kb "$d")" -ge 8 ] && DONE_2=1
  for p in "${PROFILES[@]}"; do
    d="$CHROME_DIR/$p/Local Extension Settings/$EXTENSION_ID"
    if [ ! -d "$d" ] || [ "$(dir_kb "$d")" -lt 8 ]; then DONE_3=0; break; fi
  done
}

# $1 = step number, $2 = 1 if done, $3 = label. The first unfinished step is marked as next.
setup_line() {
  local box="[ ]" next=""
  if [ "$2" -eq 1 ]; then
    box="[x]"
  elif [ -z "$NEXT_SHOWN" ]; then
    next="   <- next"
    NEXT_SHOWN=1
  fi
  say "  $box $1) $3$next"
}

show_menu() {
  clear
  show_banner
  check_progress
  NEXT_SHOWN=""
  say ""
  say "  Get set up (once)"
  setup_line 1 "$DONE_1" "Choose how to install $EXTENSION_NAME"
  setup_line 2 "$DONE_2" "Set up $EXTENSION_NAME in the master profile"
  setup_line 3 "$DONE_3" "Copy the master into Profile 1 - Profile $PROFILE_COUNT"
  say ""
  say "  On the day"
  say "      4) Launch all the profiles"
  say "      5) Test launch (1-second pause instead of ${DELAY_MIN}-${DELAY_MAX})"
  say ""
  say "  More"
  say "      6) Check status"
  say "      7) Finished with the sale? Remove Stagehand"
  say "      Q) Quit"
  say ""
  if [ -z "$NEXT_SHOWN" ]; then
    say "  All set. Choose 5 to check the copies, or 4 when it's time."
    say ""
  fi
}

# ---------------------------------------------------------------- updates

# $1 newer than $2? Both are versions like 1.4.2.
version_newer() {
  local a1 a2 a3 b1 b2 b3
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$2" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS=. read -r a1 a2 a3 <<< "$1"
  IFS=. read -r b1 b2 b3 <<< "$2"
  [ "$a1" -ne "$b1" ] && { [ "$a1" -gt "$b1" ]; return; }
  [ "$a2" -ne "$b2" ] && { [ "$a2" -gt "$b2" ]; return; }
  [ "$a3" -gt "$b3" ]
}

# Offers to update to the latest release, then restarts the menu. Only installed copies
# have a VERSION file, so a git checkout never updates itself. Quiet when offline.
check_for_update() {
  [ -n "$STAGEHAND_NO_UPDATE" ] && return 0
  [ -f "$REPO_DIR/VERSION" ] || return 0
  local here latest a
  here="$(tr -d '[:space:]' < "$REPO_DIR/VERSION")"
  latest="$(curl -fsSL --max-time 5 "$RELEASES_URL/VERSION" 2>/dev/null | tr -d '[:space:]')"
  version_newer "$latest" "$here" || return 0

  say "A new version of Stagehand is available ($here -> $latest)."
  say "Your settings and backups are kept."
  read -r -p "Update now? [Y/n] " a
  case "$a" in n|N|no|NO) return 0 ;; esac
  cd / || return 0    # the installer replaces the folder this script lives in
  if STAGEHAND_UPDATE=1 STAGEHAND_DIR="$REPO_DIR" STAGEHAND_ZIP_URL="$RELEASES_URL/stagehand.zip" \
      bash "$REPO_DIR/install.sh" </dev/null; then
    say ""
    STAGEHAND_NO_UPDATE=1 exec bash "$REPO_DIR/scripts/macos.sh"
  fi
  say "The update didn't work, so carrying on with $here."
  pause
}

main() {
  check_for_update
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
      1) one_time_setup ;;
      2) open_master ;;
      3) copy_master ;;
      4) launch_tiled ;;
      5) launch_tiled fast ;;
      6) show_status ;;
      7) remove_stagehand ;;
      q|Q) exit 0 ;;
      *) say "Please choose 1-7 or Q." ;;
    esac
    say ""
    pause
  done
}

# run the menu unless this file is being sourced (used for testing)
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main
fi
