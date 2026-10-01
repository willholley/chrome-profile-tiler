#!/bin/bash
# Stagehand - macOS installer
#
# Run it by pasting this into Terminal:
#
#   curl -fsSL https://github.com/willholley/stagehand/releases/latest/download/install.sh | bash
#
# What it does:
#   1. Downloads the latest release of this project into ~/stagehand
#   2. If you run it again later, updates the files but keeps your config.txt
#   3. Offers to start the menu, which asks for your settings the first time
#
# The menu also runs this file itself (with STAGEHAND_UPDATE=1) when it finds a newer
# release, so keep that path working.
#
# Notes for maintainers:
#   - Everything lives inside functions and the last line calls main, so a
#     half-downloaded copy of this file can't run partway.
#   - When piped (curl | bash) the script itself arrives on stdin, so every
#     prompt reads from /dev/tty instead.
#   - Environment overrides: STAGEHAND_REPO, STAGEHAND_DIR, STAGEHAND_ZIP_URL, and
#     STAGEHAND_BRANCH to install a branch instead of the latest release (for testing).
#   - STAGEHAND_UPDATE=1 skips the questions at the end (used by the menu's updater).

fail() {
  printf '\nError: %s\n' "$1" >&2
  exit 1
}

have_tty() { ( : </dev/tty ) 2>/dev/null; }

# ask "question" Y|N   (default answer)  ->  returns 0 for yes
ask() {
  local prompt="$1" def="$2" hint a
  if [ "$def" = "Y" ]; then hint="[Y/n]"; else hint="[y/N]"; fi
  read -r -p "$prompt $hint " a </dev/tty
  [ -z "$a" ] && a="$def"
  case "$a" in y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}

main() {
  REPO="${STAGEHAND_REPO:-willholley/stagehand}"
  DEST="${STAGEHAND_DIR:-$HOME/stagehand}"
  if [ -n "$STAGEHAND_BRANCH" ]; then
    ZIP_URL="https://github.com/$REPO/archive/refs/heads/$STAGEHAND_BRANCH.zip"
  else
    ZIP_URL="https://github.com/$REPO/releases/latest/download/stagehand.zip"
  fi
  ZIP_URL="${STAGEHAND_ZIP_URL:-$ZIP_URL}"

  if [ "$(uname)" != "Darwin" ] && [ -z "$STAGEHAND_ALLOW_ANY_OS" ]; then
    fail "This installer is for macOS. On Windows, see the README for the Windows steps."
  fi

  case "$DEST" in
    ""|"/"|"$HOME"|"$HOME/") fail "Refusing to install into '$DEST'." ;;
  esac

  if [ -d "/Applications/Google Chrome.app" ] || [ -d "$HOME/Applications/Google Chrome.app" ]; then
    :
  elif [ -z "$STAGEHAND_ALLOW_ANY_OS" ]; then
    printf 'Note: Google Chrome wasn'"'"'t found in /Applications. Install it before you run the menu.\n\n'
  fi

  command -v curl  >/dev/null 2>&1 || fail "curl is missing."
  command -v unzip >/dev/null 2>&1 || fail "unzip is missing."

  # A folder that exists but isn't ours: don't touch it
  if [ -e "$DEST" ] && { [ ! -d "$DEST" ] || [ ! -f "$DEST/scripts/macos.sh" ]; }; then
    fail "$DEST already exists and doesn't look like Stagehand. Move it, or set STAGEHAND_DIR to another folder."
  fi

  TMP="$(mktemp -d "${TMPDIR:-/tmp}/stagehand.XXXXXX")" || fail "Couldn't create a temporary folder."
  trap "rm -rf '$TMP'" EXIT

  echo "Downloading Stagehand..."
  curl -fsSL "$ZIP_URL" -o "$TMP/project.zip" ||
    fail "Download failed. Check your internet connection, and that the repository is public and has a release: $ZIP_URL"
  unzip -q "$TMP/project.zip" -d "$TMP/unzipped" || fail "Couldn't unzip the download."
  SRC="$(find "$TMP/unzipped" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  [ -n "$SRC" ] && [ -f "$SRC/scripts/macos.sh" ] || fail "The download didn't contain the expected files."

  # Keep the user's settings and backups across updates
  FRESH=1
  KEEP="$TMP/keep"
  mkdir -p "$KEEP"
  if [ -f "$DEST/config.txt" ]; then
    FRESH=0
    cp "$DEST/config.txt" "$KEEP/config.txt"
  fi
  [ -d "$DEST/generated" ] && cp -R "$DEST/generated" "$KEEP/generated"

  rm -rf "$DEST"
  mkdir -p "$(dirname "$DEST")"
  mv "$SRC" "$DEST" || fail "Couldn't move files into $DEST."

  [ -f "$KEEP/config.txt" ] && cp "$KEEP/config.txt" "$DEST/config.txt"
  [ -d "$KEEP/generated" ] && cp -R "$KEEP/generated" "$DEST/generated"

  chmod +x "$DEST/scripts/macos.sh" "$DEST/Start (Mac).command" 2>/dev/null
  command -v xattr >/dev/null 2>&1 && xattr -dr com.apple.quarantine "$DEST" 2>/dev/null

  SHOWN="$DEST"
  case "$DEST" in "$HOME"/*) SHOWN="~/${DEST#$HOME/}" ;; esac

  VERSION="$(cat "$DEST/VERSION" 2>/dev/null)"
  NAME="Stagehand${VERSION:+ $VERSION}"

  echo
  if [ "$FRESH" -eq 1 ]; then
    echo "Installed $NAME to $SHOWN"
  else
    echo "Updated to $NAME (your config.txt was kept)."
  fi
  [ -n "$STAGEHAND_UPDATE" ] && return 0

  if have_tty; then
    echo
    if ask "Start the Stagehand menu now?" Y; then
      bash "$DEST/scripts/macos.sh" </dev/tty
      return 0
    fi
  fi

  echo
  echo "To open the menu any time, paste this into Terminal:"
  echo
  echo "  bash $SHOWN/scripts/macos.sh"
  echo
  echo "To change your settings, choose 8 in the menu."
  echo "The menu offers to update itself when there's a new version."
}

main "$@"
