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
echo "• waiting for self-test to finish…"
sleep 10
RUN="$(gh run list --workflow self-test --limit 1 --json databaseId -q '.[0].databaseId')"
gh run watch "$RUN" --exit-status >/dev/null && bash scripts/release.sh v1
mkdir -p "$HOME/.config/ido-pipeline"
echo "Next: put Telegram details in ~/.config/ido-pipeline/telegram.env (see README), then onboard your projects."
