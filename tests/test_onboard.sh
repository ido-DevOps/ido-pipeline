#!/usr/bin/env bash
# Tests onboard.sh in --offline mode against throw-away repos. Run: bash tests/test_onboard.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ONB="$HERE/scripts/onboard.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export PIPELINE_OWNER=tester IDO_PIPELINE_CONF="$T/conf"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
fail=0
check() { if [ "$2" = "$3" ]; then echo "  ✓ $1"; else echo "  ✗ $1 (expected $2, got $3)"; fail=1; fi; }
g() { git -c commit.gpgsign=false "$@"; }

echo "onboard.sh tests"
# --- an existing project: pushed main, user busy on a feature branch with unsaved work
git init -q --bare -b main "$T/remote.git"
g init -q -b main "$T/proj"; cd "$T/proj" || exit 1
echo 'print("hi")' > app.py; echo flask > requirements.txt; g add -A; g commit -qm init
g remote add origin "$T/remote.git"; g push -q -u origin main
g checkout -qb ido/work; echo "# unsaved" >> app.py
main_before="$(git -C "$T/remote.git" rev-parse main)"

out="$(bash "$ONB" "$T/proj" --offline --yes 2>&1)"; rc=$?
check "runs successfully" 0 "$rc"
br="$(git -C "$T/remote.git" for-each-ref --format='%(refname:short)' refs/heads/pipeline/ | head -1)"
check "setup branch pushed to GitHub" 1 "$([ -n "$br" ] && echo 1 || echo 0)"
check "remote main untouched" "$main_before" "$(git -C "$T/remote.git" rev-parse main)"
git -C "$T/remote.git" show "$br:.github/workflows/pipeline.yml" > "$T/p.yml" 2>/dev/null
check "pipeline.yml points at tester/ido-pipeline@v1" 1 "$(grep -c 'tester/ido-pipeline/.github/workflows/ci.yml@v1' "$T/p.yml")"
check "dependabot detects pip" 1 "$(git -C "$T/remote.git" show "$br:.github/dependabot.yml" | grep -c 'package-ecosystem: pip')"
check "CLAUDE.md rules added" 1 "$(git -C "$T/remote.git" show "$br:CLAUDE.md" | grep -c 'ido-pipeline:start')"
check "user still on own branch" ido/work "$(git rev-parse --abbrev-ref HEAD)"
check "user's unsaved work kept" 1 "$(grep -c '# unsaved' app.py)"
check "no leftover worktrees" 1 "$(git worktree list | wc -l | tr -d ' ')"
check "no leftover local temp branch" 0 "$(git branch --list 'pipeline/*' | wc -l | tr -d ' ')"
check "guard hook installed" 1 "$([ -x .git/hooks/pre-push ] && echo 1 || echo 0)"

# --- push to main is blocked
g stash -q; g checkout -q main; echo x >> app.py; g commit -qam direct
git push -q origin main 2>/dev/null; check "direct push to main blocked" 1 "$?"
g reset -q --hard origin/main; g checkout -q ido/work; g stash pop -q

# --- --check changes nothing
n_before="$(git -C "$T/remote.git" for-each-ref refs/heads | wc -l)"
out="$(bash "$ONB" "$T/proj" --offline --check 2>&1)"; check "--check runs" 0 $?
check "--check lists changes" 1 "$(echo "$out" | grep -c 'add .github/workflows/pipeline.yml')"
check "--check pushes nothing" "$n_before" "$(git -C "$T/remote.git" for-each-ref refs/heads | wc -l)"

# --- after the PR is merged, a re-run is a no-op
g clone -q "$T/remote.git" "$T/merge"; ( cd "$T/merge" && g merge -q --no-edit "origin/$br" && ALLOW_MAIN_PUSH=1 g push -q origin main )
out="$(bash "$ONB" "$T/proj" --offline --yes 2>&1)"; check "re-run succeeds" 0 $?
check "re-run: nothing to change" 1 "$(echo "$out" | grep -c 'already follows')"

# --- a hand-written pipeline.yml is never overwritten
( cd "$T/merge" && echo "name: mine" > .github/workflows/pipeline.yml && g commit -qam mine && ALLOW_MAIN_PUSH=1 g push -q origin main )
out="$(bash "$ONB" "$T/proj" --offline --yes --ref v2 2>&1)"
check "unmanaged file left alone (warning shown)" 1 "$(echo "$out" | grep -c "isn't managed")"

# --- brand-new folder with a leaked-looking key
mkdir "$T/new"; echo 'KEY="sk-abcdefghijklmnopqrstuvwxyz123456"' > "$T/new/config.py"
out="$(bash "$ONB" "$T/new" --offline --yes 2>&1)"
check "new folder: git repo created" 1 "$([ -d "$T/new/.git" ] && echo 1 || echo 0)"
check "new folder: suspicious key file flagged" 1 "$(echo "$out" | grep -c 'config.py')"
check "new folder: stops without origin (offline)" 1 "$(echo "$out" | grep -c "no 'origin'")"

exit $fail
