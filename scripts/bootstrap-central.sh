#!/usr/bin/env bash
# One time: publish THIS folder as your private GitHub repo "ido-pipeline", let your other private repos
# use its workflows, and create the first v1 release once self-test passes.
#   bash scripts/bootstrap-central.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
gh auth status >/dev/null 2>&1 || { echo "Run: gh auth login"; exit 1; }
OWNER="$(gh api user -q .login)"
if [ ! -d .git ]; then
  git init -q -b main && git add -A && git commit -qm "ido-pipeline: initial version"
fi
if ! git remote get-url origin >/dev/null 2>&1; then
  gh repo create "$OWNER/ido-pipeline" --private --source . --remote origin >/dev/null
fi
[ -n "$(git ls-remote --heads origin main)" ] || ALLOW_MAIN_PUSH=1 git push -q -u origin main
cp hooks/pre-push .git/hooks/pre-push && chmod +x .git/hooks/pre-push
gh api -X PUT "repos/$OWNER/ido-pipeline/actions/permissions/access" -f access_level=user >/dev/null \
  && echo "✓ your other private repos may now use ido-pipeline's workflows"
echo "• waiting for self-test to start on GitHub…"
RUN=""
for _ in $(seq 1 24); do   # up to 2 minutes for GitHub to register the run
  RUN="$(gh run list --workflow self-test --commit "$(git rev-parse HEAD)" --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null)"
  [ -n "$RUN" ] && break; sleep 5
done
if [ -z "$RUN" ]; then
  echo "❌ self-test didn't start. Check: gh run list --workflow self-test   (then run: bash scripts/release.sh v1)"; exit 1
fi
echo "• self-test running (run $RUN) — usually 1–3 minutes…"
if gh run watch "$RUN" --exit-status >/dev/null; then
  bash scripts/release.sh v1
else
  echo "❌ self-test failed. See: gh run view $RUN --log-failed"; exit 1
fi
mkdir -p "$HOME/.config/ido-pipeline"
echo "Next: put Telegram details in ~/.config/ido-pipeline/telegram.env (see README), then onboard your projects."
