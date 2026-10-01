#!/usr/bin/env bash
# Run onboard.sh for every repo in repos.txt (from the assistant folder). Each one gets its own PR.
#   bash scripts/onboard-all.sh <path/to/repos.txt> [--check] [--server]
#   --server: repos live in ~/code/<name> (the assistant in ~/assistant) instead of the Mac paths
set -euo pipefail
LIST="${1:?path to repos.txt}"; shift
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER=0; ARGS=()
for a in "$@"; do if [ "$a" = --server ]; then SERVER=1; else ARGS+=("$a"); fi; done
fails=0
while IFS='|' read -r name _url path; do
  name="$(echo "$name" | xargs)"
  case "$name" in ''|'#'*|ido-pipeline) continue ;; esac
  path="$(echo "$path" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"; path="${path/#\~/$HOME}"
  if [ "$SERVER" = 1 ]; then path="$HOME/code/$name"; [ "$name" = ido-assistant ] && path="$HOME/assistant"; fi
  echo; echo "━━ $name ($path)"
  if [ ! -d "$path" ]; then echo "⚠️  folder missing — skipped"; continue; fi
  bash "$HERE/onboard.sh" "$path" --name "$name" --yes "${ARGS[@]+"${ARGS[@]}"}" || { echo "❌ $name failed"; fails=$((fails+1)); }
done < "$LIST"
echo
if [ "$fails" = 0 ]; then echo "✓ all repos processed"; else echo "❌ $fails repo(s) failed"; exit 1; fi
