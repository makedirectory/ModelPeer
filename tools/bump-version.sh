#!/usr/bin/env bash
# Bump the release version everywhere it is duplicated.
#
# VERSION is the source of truth, but the string is repeated in the CLI banner,
# the installer, the pinned curl URLs in the README, and a smoke-test assertion.
# Hand-editing them drifts; this rewrites all of them from one argument and then
# regenerates install.sh's embedded copy.
#
# Usage: tools/bump-version.sh 0.2.0
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

(( $# == 1 )) || { echo 'usage: tools/bump-version.sh <major.minor.patch>' >&2; exit 2; }
new="$1"
[[ "$new" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "bump-version: '$new' is not major.minor.patch" >&2; exit 2; }

old="$(tr -d '[:space:]' < VERSION)"
[[ -n "$old" ]] || { echo 'bump-version: VERSION is empty' >&2; exit 1; }
[[ "$old" != "$new" ]] || { echo "bump-version: already at $new" >&2; exit 2; }

# BSD and GNU sed disagree on -i; write through a temp file instead.
replace() {
  local file="$1" tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/model-peer-bump.XXXXXX")"
  sed -e "s/$old/$new/g" "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

# Every file that pins the version: the CLI banner, the installer, the pinned curl
# URLs in the README and the docs install page, the docs package manifest, and the
# smoke-test assertion.
FILES=(
  bin/model-peer
  install.sh
  README.md
  tests/smoke.sh
  documentation/docs/install.md
  documentation/docs/intro.md
  documentation/docs/usage.md
  documentation/docs/workflow.md
  documentation/package.json
)

printf '%s\n' "$new" > VERSION
for f in "${FILES[@]}"; do
  [[ -f "$f" ]] || { echo "bump-version: missing $f" >&2; exit 1; }
  replace "$f"
done

# Both generated copies are rebuilt rather than trusted to the sed above:
# install.sh embeds bin/model-peer verbatim, and examples/AGENTS.md is the output
# of `model-peer init --print`, whose managed header carries the version.
bash tools/sync-installer.sh >/dev/null
bash bin/model-peer init --print > examples/SKILL.md

# Sweep the whole tree rather than only the files listed above, so a version
# pinned in a page nobody remembered to add here still fails the bump. The
# CHANGELOG is excluded on purpose: old releases keep their own numbers.
remaining="$(git ls-files -z \
  | grep -zv '^CHANGELOG\.md$' \
  | grep -zv '^tools/bump-version\.sh$' \
  | grep -zv '^documentation/package-lock\.json$' \
  | xargs -0 grep -lF "$old" 2>/dev/null || true)"
if [[ -n "$remaining" ]]; then
  echo "bump-version: $old still present in:" >&2
  printf '%s\n' "$remaining" | sed 's/^/  /' >&2
  echo "bump-version: add these to FILES, or fix them by hand." >&2
  exit 1
fi

echo "bump-version: $old -> $new"
echo 'Remember to date the CHANGELOG entry.'
