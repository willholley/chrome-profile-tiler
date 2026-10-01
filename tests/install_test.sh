#!/bin/bash
# Tests install.sh against a built release zip, the way users get it:
#
#   .github/build.sh 0.0.1 && bash tests/install_test.sh
#
# Installs into a temporary folder (with a temporary HOME), never into ~/stagehand.

cd "$(dirname "$0")/.." || exit 1

ZIP="$PWD/build/stagehand.zip"
[ -f "$ZIP" ] || { echo "Missing $ZIP: run .github/build.sh first."; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/stagehand-test.XXXXXX")" || exit 1
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

export HOME="$WORK/home"
export STAGEHAND_DIR="$HOME/stagehand"
export STAGEHAND_ZIP_URL="file://$ZIP"
export STAGEHAND_UPDATE=1          # no "start the menu?" question at the end
export STAGEHAND_ALLOW_ANY_OS=1    # so it also runs on Linux, without Chrome installed
mkdir -p "$HOME"

FAILED=0
PASSED=0
pass() { PASSED=$((PASSED + 1)); }
fail() { FAILED=$((FAILED + 1)); printf 'FAIL: %s\n' "$*"; }
check()     { local what="$1"; shift; if "$@"; then pass; else fail "$what"; fi; }
check_not() { local what="$1"; shift; if "$@"; then fail "$what"; else pass; fi; }
check_eq()  { if [ "$2" = "$3" ]; then pass; else fail "$1"$'\n'"  expected: $2"$'\n'"  actual:   $3"; fi; }
contains()  { grep -qF "$2" <<< "$1"; }

# Same zip, with a different VERSION inside, to test updating
zip_with_version() {
  local dir="$WORK/zip-$1"
  rm -rf "$dir"; mkdir -p "$dir"
  unzip -q "$ZIP" -d "$dir"
  echo "$1" > "$dir/stagehand/VERSION"
  (cd "$dir" && zip -qr "../stagehand-$1.zip" stagehand)
  echo "file://$WORK/stagehand-$1.zip"
}

# ---------------------------------------------------------------- the zip itself

listing="$(unzip -Z1 "$ZIP")"
for f in stagehand/VERSION stagehand/install.sh stagehand/config.txt stagehand/scripts/macos.sh \
         stagehand/scripts/windows.ps1 "stagehand/Start (Mac).command" "stagehand/Start (Windows).bat" \
         stagehand/README.md; do
  check "the zip contains $f" contains "$listing" "$f"
done
check_not "the zip leaves out .github" contains "$listing" ".github"
check_not "the zip leaves out tests" contains "$listing" "stagehand/tests"

unzip -q "$ZIP" -d "$WORK/unzipped"
Z="$WORK/unzipped/stagehand"
crlf() { grep -q $'\r' "$1"; }
check     "windows.ps1 has Windows line endings"      crlf "$Z/scripts/windows.ps1"
check     "Start (Windows).bat has Windows line endings" crlf "$Z/Start (Windows).bat"
check_not "macos.sh has Unix line endings"            crlf "$Z/scripts/macos.sh"
check_not "install.sh has Unix line endings"          crlf "$Z/install.sh"
check_not "Start (Mac).command has Unix line endings" crlf "$Z/Start (Mac).command"
check_not "windows.ps1 is ASCII only (Windows PowerShell 5.1 misreads anything else)" \
  env LC_ALL=C grep -q '[^[:print:][:space:]]' "$Z/scripts/windows.ps1"

# ---------------------------------------------------------------- fresh install, piped like the README

out="$(bash < build/install.sh 2>&1)"
check "a fresh install succeeds" test $? -eq 0
check "it says it was installed" contains "$out" "Installed Stagehand $(cat build/VERSION) to ~/stagehand"
check_eq "VERSION is installed" "$(cat build/VERSION)" "$(cat "$STAGEHAND_DIR/VERSION")"
check "macos.sh is executable" test -x "$STAGEHAND_DIR/scripts/macos.sh"
check "Start (Mac).command is executable" test -x "$STAGEHAND_DIR/Start (Mac).command"
check "the default config.txt is installed" cmp -s config.txt "$STAGEHAND_DIR/config.txt"

# ---------------------------------------------------------------- update keeps settings and backups

echo "PROFILE_COUNT=3" >> "$STAGEHAND_DIR/config.txt"
mkdir -p "$STAGEHAND_DIR/generated"
echo "policy" > "$STAGEHAND_DIR/generated/install-mode"
before="$(cat "$STAGEHAND_DIR/config.txt")"

out="$(STAGEHAND_ZIP_URL="$(zip_with_version 99.0.0)" bash build/install.sh 2>&1)"
check "an update succeeds" test $? -eq 0
check "it says it was updated" contains "$out" "Updated to Stagehand 99.0.0 (your config.txt was kept)."
check_eq "the new VERSION is installed" "99.0.0" "$(cat "$STAGEHAND_DIR/VERSION")"
check_eq "config.txt is kept" "$before" "$(cat "$STAGEHAND_DIR/config.txt")"
check_eq "generated/ is kept" "policy" "$(cat "$STAGEHAND_DIR/generated/install-mode" 2>/dev/null)"
leftovers="$(find "$HOME" -maxdepth 1 -name 'stagehand.previous.*')"
check_eq "the old version is removed" "" "$leftovers"

# ---------------------------------------------------------------- failures leave things alone

out="$(STAGEHAND_ZIP_URL="file://$WORK/missing.zip" bash build/install.sh 2>&1)"
check_not "a failed download fails" test $? -eq 0
check "it says the download failed" contains "$out" "Download failed"
check_eq "and leaves the install alone" "99.0.0" "$(cat "$STAGEHAND_DIR/VERSION")"

mkdir -p "$WORK/notours/stagehand"
(cd "$WORK/notours" && zip -qr ../notours.zip stagehand)
out="$(STAGEHAND_ZIP_URL="file://$WORK/notours.zip" bash build/install.sh 2>&1)"
check_not "a zip without Stagehand in it fails" test $? -eq 0
check "it says the download was wrong" contains "$out" "didn't contain the expected files"
check_eq "and leaves the install alone" "99.0.0" "$(cat "$STAGEHAND_DIR/VERSION")"

mkdir -p "$HOME/Documents"
echo "mine" > "$HOME/Documents/notes.txt"
out="$(STAGEHAND_DIR="$HOME/Documents" bash build/install.sh 2>&1)"
check_not "it refuses a folder that isn't Stagehand" test $? -eq 0
check "it says why" contains "$out" "doesn't look like Stagehand"
check_eq "and leaves the folder alone" "notes.txt" "$(ls "$HOME/Documents")"

for dest in "$HOME" "$HOME/" "/"; do
  out="$(STAGEHAND_DIR="$dest" bash build/install.sh 2>&1)"
  check_not "it refuses to install into '$dest'" test $? -eq 0
  check "it says why ('$dest')" contains "$out" "Refusing to install"
done

# ---------------------------------------------------------------- done

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
