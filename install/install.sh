#!/usr/bin/env bash
#
# QuickPatch installer (git-based).
#
#   curl -fsSL https://raw.githubusercontent.com/letssuhail/quickpatch-cli/main/install/install.sh | bash
#
# Clones the QuickPatch CLI into ~/.quickpatch (the install root IS the git
# checkout, so `quickpatch upgrade` can `git reset` to the latest), then builds
# the `quickpatch` snapshot. Flutter + the patched iOS engine are fetched on
# first run by the CLI itself.
#
# Override the location with QUICKPATCH_ROOT, the source with QUICKPATCH_REPO_URL.
set -euo pipefail

REPO_URL="${QUICKPATCH_REPO_URL:-https://github.com/letssuhail/quickpatch-cli.git}"
BRANCH="${QUICKPATCH_BRANCH:-main}"
QUICKPATCH_ROOT="${QUICKPATCH_ROOT:-$HOME/.quickpatch}"
BIN_DIR="$QUICKPATCH_ROOT/bin"

info() { printf '\033[36m%s\033[0m\n' "$*"; }
ok()   { printf '\033[32m%s\033[0m\n' "$*"; }
err()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }

command -v git >/dev/null 2>&1 || { err "git is required but not found on PATH."; exit 1; }

if [ -d "$QUICKPATCH_ROOT/.git" ]; then
  # Already a git checkout: update in place.
  info "Updating existing QuickPatch checkout at $QUICKPATCH_ROOT..."
  git -C "$QUICKPATCH_ROOT" fetch --depth 1 origin "$BRANCH"
  git -C "$QUICKPATCH_ROOT" reset --hard "origin/$BRANCH"
elif [ -e "$QUICKPATCH_ROOT" ]; then
  # Legacy / manual install: clone into a temp dir and overlay the checkout,
  # preserving any existing bin/cache (built snapshot, bundled Flutter).
  info "Found a non-git QuickPatch at $QUICKPATCH_ROOT; converting to a git checkout..."
  TMP="$(mktemp -d)"
  git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$TMP"
  cp -R "$TMP/.git" "$QUICKPATCH_ROOT/.git"
  ( cd "$QUICKPATCH_ROOT" && git reset --hard "origin/$BRANCH" 2>/dev/null || git -C "$QUICKPATCH_ROOT" checkout -f "$BRANCH" )
  rm -rf "$TMP"
else
  info "Cloning QuickPatch ($BRANCH) into $QUICKPATCH_ROOT..."
  git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$QUICKPATCH_ROOT"
fi

# Resolve a Dart SDK to compile the snapshot with.
find_dart() {
  if command -v dart >/dev/null 2>&1; then command -v dart; return; fi
  if [ -x "$BIN_DIR/cache/flutter/bin/dart" ]; then echo "$BIN_DIR/cache/flutter/bin/dart"; return; fi
  if command -v flutter >/dev/null 2>&1; then
    local fdart; fdart="$(dirname "$(command -v flutter)")/cache/dart-sdk/bin/dart"
    [ -x "$fdart" ] && { echo "$fdart"; return; }
  fi
  echo ""
}
DART="$(find_dart)"
if [ -z "$DART" ]; then
  err "A Dart or Flutter SDK is required to build the CLI. Install Flutter (https://flutter.dev) and re-run."
  exit 1
fi

mkdir -p "$BIN_DIR/cache"
info "Building quickpatch (one-time, ~30s)..."
( cd "$QUICKPATCH_ROOT/quickpatch_cli" && "$DART" pub get >/dev/null )
"$DART" compile exe "$QUICKPATCH_ROOT/quickpatch_cli/bin/quickpatch.dart" \
  -o "$BIN_DIR/cache/quickpatch"
git -C "$QUICKPATCH_ROOT" rev-parse HEAD > "$BIN_DIR/cache/.quickpatch.revision"

if [ ! -x "$BIN_DIR/cache/quickpatch" ]; then
  err "Build failed: snapshot was not produced."
  exit 1
fi

ok "QuickPatch installed at $QUICKPATCH_ROOT"
info "On your first 'quickpatch release' or 'quickpatch patch', QuickPatch downloads"
info "its pinned Flutter + iOS engine (~one-time, a few minutes)."

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    echo
    info "Add QuickPatch to your PATH (append to ~/.zshrc, ~/.bashrc, or ~/.profile):"
    echo
    echo "    export PATH=\"\$PATH:$BIN_DIR\""
    echo
    info "Then restart your terminal and run: quickpatch --help"
    ;;
esac
