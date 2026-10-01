#!/usr/bin/env bash
# Tests conflict_guard.py --local on throw-away repos. Run: bash tests/test_conflict_guard.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$HERE/scripts/conflict_guard.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0
g() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
check() { # name expected_exit actual_exit
  if [ "$2" = "$3" ]; then echo "  ✓ $1"; else echo "  ✗ $1 (expected exit $2, got $3)"; fail=1; fi
}

cd "$T"; g init -q -b main repo; cd repo
printf 'line1\nline2\nline3\nline4\nline5\n' > app.py; printf 'a\n' > other.txt
g add -A; g commit -qm base

g checkout -qb one;  sed -i 's/line2/ONE changed line2/' app.py; g commit -qam one
g checkout -q main; g checkout -qb two;  sed -i 's/line2/TWO changed line2/' app.py; g commit -qam two
g checkout -q main; g checkout -qb three; echo b >> other.txt; g commit -qam three
g checkout -q main; g checkout -qb four;  sed -i 's/line5/FOUR line5/' app.py; g commit -qam four
g checkout -q main
refs_before="$(git for-each-ref --format='%(refname) %(objectname)' refs/heads | grep -v refs/heads/main)"

echo "Conflict Guard tests"
set +e
python3 "$GUARD" --local one three four >/dev/null;           check "different lines/files → clean" 0 $?
out="$(python3 "$GUARD" --local one two --json)";              check "same line in two branches → conflict" 1 $?
echo "$out" | grep -q '"line": 2';                              check "reports the conflicting line number" 0 $?
echo "$out" | grep -q 'ONE changed line2';                      check "shows both versions" 0 $?
g checkout -q main; sed -i 's/line2/MAIN changed line2/' app.py; g commit -qam main-change
python3 "$GUARD" --local three --json >/dev/null;              check "branch vs new main, untouched lines → clean" 0 $?
out="$(python3 "$GUARD" --local one --json)";                  check "branch vs main, same line → conflict" 1 $?
echo "$out" | grep -q '"base"';                                 check "reported as conflict with main" 0 $?

# Safety: the guard must never move a branch or leave anything behind
refs_after="$(git for-each-ref --format='%(refname) %(objectname)' refs/heads | grep -v refs/heads/main)"
[ "$refs_before" = "$refs_after" ];                             check "no branch was moved" 0 $?
[ "$(git worktree list | wc -l)" = 1 ];                         check "temporary worktree removed" 0 $?
[ "$(git rev-parse --abbrev-ref HEAD)" = main ];                check "user's checkout untouched" 0 $?
[ -z "$(git status --porcelain)" ];                             check "working tree still clean" 0 $?
exit $fail
