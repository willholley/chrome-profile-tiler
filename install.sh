#!/bin/bash
# Chrome Profile Tiler - macOS installer
#
# Run it by pasting this into Terminal:
#
#   curl -fsSL https://raw.githubusercontent.com/willholley/chrome-profile-tiler/main/install.sh | bash
#
# What it does:
#   1. Downloads the latest copy of this project into ~/chrome-profile-tiler
#   2. If you run it again later, updates the files but keeps your config.txt
#   3. Offers to open config.txt for editing, then offers to start the menu
#
# Notes for maintainers:
#   - Everything lives inside functions and the last line calls main, so a
#     half-downloaded copy of this file can't run partway.
#   - When piped (curl | bash) the script itself arrives on stdin, so every
#     prompt reads from /dev/tty instead.
#   - Environment overrides: CPT_REPO, CPT_BRANCH, CPT_DIR, CPT_ZIP_URL.

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
  REPO="${CPT_REPO:-willholley/chrome-profile-tiler}"
  BRANCH="${CPT_BRANCH:-main}"
  DEST="${CPT_DIR:-$HOME/chrome-profile-tiler}"
  ZIP_URL="${CPT_ZIP_URL:-https://github.com/$REPO/archive/refs/heads/$BRANCH.zip}"

  if [ "$(uname)" != "Darwin" ] && [ -z "$CPT_ALLOW_ANY_OS" ]; then
    fail "This installer is for macOS. On Windows, see the README for the Windows steps."
  fi

  if [ -z "$CPT_ZIP_URL" ]; then
    case "$REPO" in
      *willholley*) fail "install.sh still says willholley. Edit the REPO line (or set CPT_REPO) first." ;;
    esac
  fi

  case "$DEST" in
    ""|"/"|"$HOME"|"$HOME/") fail "Refusing to install into '$DEST'." ;;
  esac

  if [ -d "/Applications/Google Chrome.app" ] || [ -d "$HOME/Applications/Google Chrome.app" ]; then
    :
  elif [ -z "$CPT_ALLOW_ANY_OS" ]; then
    printf 'Note: Google Chrome wasn'"'"'t found in /Applications. Install it before you run the menu.\n\n'
  fi

  command -v curl  >/dev/null 2>&1 || fail "curl is missing."
  command -v unzip >/dev/null 2>&1 || fail "unzip is missing."

  # A folder that exists but isn't ours: don't touch it
  if [ -d "$DEST" ] && [ ! -f "$DEST/scripts/macos.sh" ]; then
    fail "$DEST already exists and doesn't look like Chrome Profile Tiler. Move it, or set CPT_DIR to another folder."
  fi

  TMP="$(mktemp -d "${TMPDIR:-/tmp}/cpt.XXXXXX")" || fail "Couldn't create a temporary folder."
  trap "rm -rf '$TMP'" EXIT

  echo "Downloading Chrome Profile Tiler..."
  curl -fsSL "$ZIP_URL" -o "$TMP/project.zip" ||
    fail "Download failed. Check your internet connection and that the GitHub repository is public: $ZIP_URL"
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

  echo
  if [ "$FRESH" -eq 1 ]; then
    echo "Installed to $SHOWN"
  else
    echo "Updated $SHOWN (your config.txt was kept)."
  fi

  if have_tty; then
    echo
    if [ "$FRESH" -eq 1 ]; then
      echo "Before you start, check the settings (which extension, which page, how many profiles)."
      if ask "Open config.txt in TextEdit now?" Y; then
        open -e "$DEST/config.txt"
        read -r -p "Make your changes, press Cmd+S to save, close the window, then press Enter here... " _ </dev/tty
      fi
    fi
    echo
    if ask "Start the Chrome Profile Tiler menu now?" Y; then
      bash "$DEST/scripts/macos.sh" </dev/tty
      return 0
    fi
  fi

  echo
  echo "To open the menu any time, paste this into Terminal:"
  echo
  echo "  bash $SHOWN/scripts/macos.sh"
  echo
  echo "To edit your settings:  open -e $SHOWN/config.txt"
  echo "To update to the latest version, run the install line again (your settings are kept)."
}

main "$@"
