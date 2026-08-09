#!/usr/bin/env bash
# Rebuild the copy of bin/model-peer that install.sh embeds for the curl path.
#
# install.sh must stay standalone, so it carries the script inline rather than
# reading it from the repository. That duplication is verified by tests/smoke.sh
# (it installs and cmp's the result); run this whenever bin/model-peer changes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT/install.sh"
SOURCE="$ROOT/bin/model-peer"
MARKER='__MODEL_PEER__'

[[ -f "$INSTALLER" && -f "$SOURCE" ]] || { echo 'sync-installer: missing install.sh or bin/model-peer' >&2; exit 1; }

grep -Fq "<<'$MARKER'" "$INSTALLER" || { echo "sync-installer: opening $MARKER heredoc not found" >&2; exit 1; }

tmp="$(mktemp "${TMPDIR:-/tmp}/model-peer-installer.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

awk -v marker="$MARKER" -v src="$SOURCE" '
  state == 0 {
    print
    if (index($0, "<<\047" marker "\047") > 0) {
      while ((getline line < src) > 0) print line
      close(src)
      state = 1
    }
    next
  }
  state == 1 {
    if ($0 == marker) { print; state = 2 }
    next
  }
  { print }
' "$INSTALLER" > "$tmp"

grep -Fqx "$MARKER" "$tmp" || { echo "sync-installer: closing $MARKER marker lost; refusing to write" >&2; exit 1; }
bash -n "$tmp" || { echo 'sync-installer: regenerated installer failed syntax check' >&2; exit 1; }

cat "$tmp" > "$INSTALLER"
echo 'sync-installer: install.sh now embeds the current bin/model-peer.'
