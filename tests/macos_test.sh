#!/bin/bash
# Unit tests for scripts/macos.sh. Run with the macOS /bin/bash (3.2), which is what users have:
#
#   /bin/bash tests/macos_test.sh
#
# Loads the script without starting the menu, then calls its functions one at a time.
# Nothing here touches Chrome, the real config.txt or the screen.

# The tests set the script's globals, which shellcheck can't see being read
# shellcheck disable=SC2034
# shellcheck source-path=SCRIPTDIR/..

cd "$(dirname "$0")/.." || exit 1

WORK="$(mktemp -d "${TMPDIR:-/tmp}/stagehand-test.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT

export CONFIG_FILE="$WORK/config.txt"
export CHROME_DATA_DIR="$WORK/chrome"
export STAGEHAND_NO_UPDATE=1
source scripts/macos.sh
# Keep backups and other generated files out of the real checkout
REPO_DIR="$WORK/repo"
MODE_FILE="$REPO_DIR/generated/install-mode"
mkdir -p "$REPO_DIR" "$CHROME_DIR"

FAILED=0
PASSED=0

pass() { PASSED=$((PASSED + 1)); }
fail() { FAILED=$((FAILED + 1)); printf 'FAIL: %s\n' "$*"; }

# check "description" command args...   ->  passes if the command succeeds
check() {
  local what="$1"; shift
  if "$@"; then pass; else fail "$what"; fi
}

# check_not "description" command args...   ->  passes if the command fails
check_not() {
  local what="$1"; shift
  if "$@"; then fail "$what"; else pass; fi
}

# check_eq "description" expected actual
check_eq() {
  if [ "$2" = "$3" ]; then pass; else fail "$1"$'\n'"  expected: $2"$'\n'"  actual:   $3"; fi
}

has_files() { compgen -G "$1" >/dev/null; }

# Writes stdin to config.txt and resets the settings to the script's defaults
write_config() {
  cat > "$CONFIG_FILE"
  STARTUP_URL=""; SET_STARTUP_PAGE="yes"; PROFILE_COUNT=12
  DELAY_MIN=45; DELAY_MAX=75; INSTALL_TIMEOUT=90; MAX_SCREENS=0; ONLY_SCREEN=0
}

# ---------------------------------------------------------------- version_newer

check     "1.0.1 is newer than 1.0.0"       version_newer 1.0.1 1.0.0
check     "1.1.0 is newer than 1.0.9"       version_newer 1.1.0 1.0.9
check     "2.0.0 is newer than 1.9.9"       version_newer 2.0.0 1.9.9
check     "1.10.0 is newer than 1.9.0"      version_newer 1.10.0 1.9.0
check_not "1.0.0 is not newer than itself"  version_newer 1.0.0 1.0.0
check_not "1.0.0 is not newer than 1.0.1"   version_newer 1.0.0 1.0.1
check_not "1.9.0 is not newer than 1.10.0"  version_newer 1.9.0 1.10.0
check_not "empty (offline) is never newer"  version_newer "" 1.0.0
check_not "an HTML error page is never newer" version_newer "<html>" 1.0.0
check_not "a partial version is never newer" version_newer 2.0 1.0.0
check_not "nothing is newer than junk"      version_newer 1.0.0 "dev"

# ---------------------------------------------------------------- trim

check_eq "trim removes spaces and tabs" "a b" "$(trim $'  \ta b \t ')"
check_eq "trim of blanks is empty" "" "$(trim '   ')"

# ---------------------------------------------------------------- load_config / validate_config

write_config <<'EOF'
# a comment
STARTUP_URL = https://example.com/a=b
PROFILE_COUNT=3
  DELAY_MIN=08
DELAY_MAX=09
#MAX_SCREENS=5
UNKNOWN_KEY=whatever
not a setting
EOF
check "load_config reads a normal file" load_config
check_eq "spaces around = are ignored, and = in the value is kept" "https://example.com/a=b" "$STARTUP_URL"
check_eq "commented-out settings are ignored" "0" "$MAX_SCREENS"
check "validate_config accepts it" validate_config
check_eq "08 is read as 8, not octal" "8" "$DELAY_MIN"
check_eq "09 is read as 9, not octal" "9" "$DELAY_MAX"
check_eq "PROFILES has one entry per profile" "Profile 1|Profile 2|Profile 3" "$(IFS='|'; echo "${PROFILES[*]}")"

printf 'STARTUP_URL=https://example.com\r\nPROFILE_COUNT=4\r\nDELAY_MIN=1\r\nDELAY_MAX=2' | write_config
check "load_config reads Windows line endings and no final newline" load_config
check_eq "the last line is read without a final newline" "2" "$DELAY_MAX"
check_eq "carriage returns are removed" "https://example.com" "$STARTUP_URL"
check "and validates" validate_config

write_config <<'EOF'
PROFILE_COUNT=twelve
EOF
load_config
check_not "validate_config rejects a non-number" validate_config >/dev/null

write_config <<'EOF'
PROFILE_COUNT=0
EOF
load_config
check_not "validate_config rejects PROFILE_COUNT=0" validate_config >/dev/null

write_config <<'EOF'
DELAY_MIN=80
DELAY_MAX=70
EOF
load_config
check_not "validate_config rejects DELAY_MIN > DELAY_MAX" validate_config >/dev/null

write_config <<'EOF'
MAX_SCREENS=-1
EOF
load_config
check_not "validate_config rejects a negative number" validate_config >/dev/null

rm -f "$CONFIG_FILE"
check_not "load_config fails when config.txt is missing" load_config >/dev/null

# ---------------------------------------------------------------- set_config_value

write_config <<'EOF'
# Settings
STARTUP_URL=https://old.example.com

# How many
PROFILE_COUNT=12
#MAX_SCREENS=0
#MAX_SCREENS=1
EOF

set_config_value STARTUP_URL "https://new.example.com"
set_config_value MAX_SCREENS 2
set_config_value INSTALL_TIMEOUT 30
check_eq "set_config_value replaces, switches on and adds, keeping comments" "# Settings
STARTUP_URL=https://new.example.com

# How many
PROFILE_COUNT=12
MAX_SCREENS=2
#MAX_SCREENS=1
INSTALL_TIMEOUT=30" "$(cat "$CONFIG_FILE")"
check_not "set_config_value leaves no temporary file" test -e "$CONFIG_FILE.tmp"

set_config_value MAX_SCREENS 3
check_eq "once switched on, the setting is updated in place" "MAX_SCREENS=3
#MAX_SCREENS=1" "$(grep MAX_SCREENS "$CONFIG_FILE")"

printf 'DELAY_MIN=1\r\nDELAY_MAX=2\r\n' > "$CONFIG_FILE"
set_config_value DELAY_MAX 5
check_eq "set_config_value handles Windows line endings" "DELAY_MIN=1
DELAY_MAX=5" "$(cat "$CONFIG_FILE")"

rm -f "$CONFIG_FILE"
set_config_value STARTUP_URL "https://example.com"
check_eq "set_config_value creates a missing config.txt" "STARTUP_URL=https://example.com" "$(cat "$CONFIG_FILE")"

# ---------------------------------------------------------------- edit_settings

write_config <<'EOF'
STARTUP_URL=https://old.example.com
PROFILE_COUNT=12
DELAY_MIN=45
DELAY_MAX=75
INSTALL_TIMEOUT=soon
EOF
load_config
# A bad address, then a good one; Enter keeps the profile count; a min > max pair, then a good
# pair; a bad screen, then screen 2; then a value for the broken INSTALL_TIMEOUT
answers='not a url
https://new.example.com

80
70
10
20
second
2
60
'
edit_settings <<< "$answers" >/dev/null 2>&1
check_eq "edit_settings saves the answers, after asking again for bad ones" "STARTUP_URL=https://new.example.com
PROFILE_COUNT=12
DELAY_MIN=10
DELAY_MAX=20
INSTALL_TIMEOUT=60
ONLY_SCREEN=2" "$(cat "$CONFIG_FILE")"
check_eq "edit_settings reloads the settings it saved" "10 20" "$DELAY_MIN $DELAY_MAX"

write_config <<'EOF'
STARTUP_URL=https://old.example.com
EOF
load_config
( edit_settings < /dev/null >/dev/null 2>&1 )
check_not "edit_settings gives up when the input is closed" test $? -eq 0
check_eq "and leaves config.txt alone" "STARTUP_URL=https://old.example.com" "$(cat "$CONFIG_FILE")"

# ---------------------------------------------------------------- build_bounds

SCREENS=("0 25 1200 900")
MAX_SCREENS=0
build_bounds 4 >/dev/null
check_eq "4 windows on one screen make a 2x2 grid" \
  "0 25 600 475|600 25 1200 475|0 475 600 925|600 475 1200 925" "$(IFS='|'; echo "${BOUNDS[*]}")"

build_bounds 3 >/dev/null
check_eq "3 windows on one screen use a 2x2 grid with a gap" \
  "0 25 600 475|600 25 1200 475|0 475 600 925" "$(IFS='|'; echo "${BOUNDS[*]}")"

build_bounds 12 >/dev/null
check_eq "12 windows on one screen make 12 windows" "12" "${#BOUNDS[@]}"
check_eq "12 windows use a 4x3 grid" "900 625 1200 925" "${BOUNDS[11]}"

SCREENS=("0 25 1000 800" "1000 0 800 600")
build_bounds 3 >/dev/null
check_eq "3 windows over 2 screens: 2 on the first, 1 filling the second" \
  "0 25 500 825|500 25 1000 825|1000 0 1800 600" "$(IFS='|'; echo "${BOUNDS[*]}")"

MAX_SCREENS=1
build_bounds 3 >/dev/null
check_eq "MAX_SCREENS=1 puts every window on the first screen" \
  "0 25 500 425|500 25 1000 425|0 425 500 825" "$(IFS='|'; echo "${BOUNDS[*]}")"

MAX_SCREENS=5
build_bounds 2 >/dev/null
check_eq "MAX_SCREENS above the number of screens uses them all" \
  "0 25 1000 825|1000 0 1800 600" "$(IFS='|'; echo "${BOUNDS[*]}")"

MAX_SCREENS=0
SCREENS=("0 0 900 900" "900 0 900 900" "1800 0 900 900")
build_bounds 1 >/dev/null
check_eq "more screens than windows leaves the extra screens empty" "0 0 900 900" "$(IFS='|'; echo "${BOUNDS[*]}")"

ONLY_SCREEN=2
build_bounds 2 >/dev/null
check_eq "ONLY_SCREEN=2 puts every window on the second screen" \
  "900 0 1350 900|1350 0 1800 900" "$(IFS='|'; echo "${BOUNDS[*]}")"

MAX_SCREENS=1
build_bounds 1 >/dev/null
check_eq "ONLY_SCREEN wins over MAX_SCREENS" "900 0 1800 900" "$(IFS='|'; echo "${BOUNDS[*]}")"

MAX_SCREENS=0
ONLY_SCREEN=4
out="$(build_bounds 3)"
check_eq "ONLY_SCREEN past the last screen says so" \
  "ONLY_SCREEN is 4, but there are only 3 screens. Using them all." "${out%%$'\n'*}"
build_bounds 3 >/dev/null
check_eq "and falls back to every screen" "3" "${#BOUNDS[@]}"
check_eq "starting on the first" "0 0 900 900" "${BOUNDS[0]}"
ONLY_SCREEN=0

# ---------------------------------------------------------------- tidy_local_state

LS="$CHROME_DIR/Local State"
cat > "$LS" <<'EOF'
{"browser":{"x":1},"profile":{"info_cache":{"Default":{"name":"Me"},"Profile 1":{"name":"P1"},"Profile 2":{"name":"P2"},"Autofill Master":{"name":"M"}},"profiles_order":["Default","Profile 1","Profile 2","Autofill Master"],"last_active_profiles":["Profile 1","Default"],"last_used":"Profile 2"}}
EOF
check "tidy_local_state succeeds" tidy_local_state "Profile 1" "Profile 2"
# Compare by parsing, so key order doesn't matter
summary="$(perl -MJSON::PP -e '
  local $/; open my $f, "<", $ARGV[0] or die; my $d = decode_json(<$f>); my $p = $d->{profile};
  print join(" ; ",
    join(",", sort keys %{ $p->{info_cache} }),
    join(",", @{ $p->{profiles_order} }),
    join(",", @{ $p->{last_active_profiles} }),
    $p->{last_used}, $d->{browser}{x});' "$LS")"
check_eq "tidy_local_state removes only the named profiles" \
  "Autofill Master,Default ; Default,Autofill Master ; Default ; Default ; 1" "$summary"
check "tidy_local_state keeps a backup" has_files "$REPO_DIR/generated/Local State.backup-*"

printf '{"profile": {"info_cache": ' > "$LS"
check_not "tidy_local_state fails on a damaged file" tidy_local_state "Profile 1"
check_eq "and leaves it as it was" '{"profile": {"info_cache": ' "$(cat "$LS")"
check_not "and leaves no temporary file" test -e "$LS.tmp"

rm -f "$LS"
check "tidy_local_state does nothing when Chrome has never run" tidy_local_state "Profile 1"

# ---------------------------------------------------------------- done

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
