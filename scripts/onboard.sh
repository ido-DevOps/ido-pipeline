#!/usr/bin/env bash
# onboard.sh — put a project on GitHub with the standard ido-pipeline (CI, security, Conflict Guard,
# optional deploy), or update it to the latest standard. Safe to run again and again.
#
#   bash onboard.sh <project-folder> [options]
#     --name NAME     GitHub repo name (default: folder name, lower-case)
#     --deploy        also add auto-deploy (asks for server details once)
#     --check         dry run: show what would change, touch nothing
#     --yes           don't ask for confirmation (used by the assistant)
#     --ref REF       ido-pipeline version to pin (default: v1)
#     --offline       skip all GitHub API calls (tests)
#
# SAFETY — what this script will NEVER do:
#   • push to main (except the very first push of a brand-new, empty repo)
#   • force-push, delete a remote branch, reset, rebase or stash
#   • touch your working folder: all changes are made in a temporary worktree on a new
#     branch "pipeline/setup-<time>", pushed, and proposed as a Pull Request for you to merge
#   • overwrite files it doesn't own (it only updates files marked "Managed by ido-pipeline")
set -euo pipefail

PIPE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TPL="$PIPE/templates"
CONF="${IDO_PIPELINE_CONF:-$HOME/.config/ido-pipeline}"

die()  { echo "❌ $*" >&2; exit 1; }
info() { echo "• $*"; }
ok()   { echo "✓ $*"; }
warn() { echo "⚠️  $*"; }

# ------------------------------------------------------------------ arguments
DIR=""; NAME=""; DEPLOY=0; CHECK=0; YES=0; REF="v1"; OFFLINE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="${2:?}"; shift 2 ;;
    --deploy) DEPLOY=1; shift ;;
    --check) CHECK=1; shift ;;
    --yes) YES=1; shift ;;
    --ref) REF="${2:?}"; shift 2 ;;
    --offline) OFFLINE=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    -*) die "unknown option $1" ;;
    *) [ -z "$DIR" ] || die "only one folder"; DIR="$1"; shift ;;
  esac
done
[ -n "$DIR" ] || die "usage: onboard.sh <project-folder> [--deploy] [--check] [--yes]"
[ -d "$DIR" ] || die "folder not found: $DIR"
DIR="$(cd "$DIR" && pwd)"
[ -n "$NAME" ] || NAME="$(basename "$DIR" | tr '[:upper:] ' '[:lower:]-')"
command -v git >/dev/null || die "git is not installed"

confirm() {  # $1 = question
  [ "$YES" = 1 ] && return 0
  local a; read -r -p "$1 [y/N] " a; [ "$a" = y ] || [ "$a" = Y ]
}

if [ "$OFFLINE" = 0 ]; then
  command -v gh >/dev/null || die "GitHub CLI missing (Mac: brew install gh · server: apt install gh)"
  gh auth status >/dev/null 2>&1 || die "not logged in to GitHub: gh auth login"
  OWNER="${PIPELINE_OWNER:-$(gh api user -q .login)}"
else
  OWNER="${PIPELINE_OWNER:-owner}"
fi

g() { git -C "$DIR" "$@"; }

# ------------------------------------------------------------------ 1. make sure it's a git repo with a first commit
scan_secrets() {  # $1 = folder; prints suspicious files (cheap local check, CI runs gitleaks properly)
  git -C "$1" ls-files -z --cached --others --exclude-standard 2>/dev/null \
    | xargs -0 grep -IlE 'sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|xox[baprs]-[A-Za-z0-9-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|[0-9]{8,10}:AA[A-Za-z0-9_-]{30,}' /dev/null 2>/dev/null \
    | sed "s#^#    #" || true
}

if [ ! -d "$DIR/.git" ]; then
  [ "$CHECK" = 1 ] && { info "would: git init, first commit, create private repo $OWNER/$NAME"; exit 0; }
  info "$DIR is not a git repo yet — creating one"
  g init -q -b main
  [ -f "$DIR/.gitignore" ] || cp "$TPL/gitignore" "$DIR/.gitignore"
  echo "Files that will go into the first commit:"; g add -A --dry-run | sed 's/^add /    /' | head -60
  sus="$(scan_secrets "$DIR")"
  if [ -n "$sus" ]; then warn "these files look like they contain keys/tokens:"; echo "$sus"; warn "add them to .gitignore first!"; fi
  confirm "Commit these files?" || die "stopped — nothing was committed (fix .gitignore and run again)"
  g add -A
  g -c user.name="$(git config user.name || echo Ido)" -c user.email="$(git config user.email || echo ido@localhost)" \
    -c commit.gpgsign=false commit -qm "Initial commit"
  ok "first commit created"
fi
[ -n "$(g rev-parse --verify -q HEAD)" ] || die "repo has no commits yet — commit something first"

# ------------------------------------------------------------------ 2. remote on GitHub
if ! g remote get-url origin >/dev/null 2>&1; then
  [ "$OFFLINE" = 1 ] && die "no 'origin' remote (offline mode)"
  [ "$CHECK" = 1 ] && { info "would create private repo $OWNER/$NAME"; exit 0; }
  if gh repo view "$OWNER/$NAME" >/dev/null 2>&1; then
    g remote add origin "https://github.com/$OWNER/$NAME.git"; ok "linked to existing $OWNER/$NAME"
  else
    gh repo create "$OWNER/$NAME" --private --source "$DIR" --remote origin >/dev/null; ok "created private repo $OWNER/$NAME"
  fi
fi
if [ -z "$(g ls-remote --heads origin main 2>/dev/null)" ]; then
  [ "$CHECK" = 1 ] && { info "would push the first commit to the empty remote"; exit 0; }
  [ "$(g rev-parse --abbrev-ref HEAD)" = main ] || die "remote is empty and you're not on 'main' — switch to main first"
  ALLOW_MAIN_PUSH=1 g push -q -u origin main; ok "first push of main (only time main is pushed directly)"
fi

# guard hook in this checkout
if [ "$CHECK" = 0 ]; then
  hooks="$(g rev-parse --git-path hooks)"; case "$hooks" in /*) ;; *) hooks="$DIR/$hooks";; esac
  mkdir -p "$hooks"; cp "$PIPE/hooks/pre-push" "$hooks/pre-push"; chmod +x "$hooks/pre-push"
fi

# ------------------------------------------------------------------ 3. prepare changes in a temporary worktree
g fetch -q origin main
BR="pipeline/setup-$(date +%Y%m%d-%H%M%S)"
WT="$(mktemp -d)/wt"
cleanup() {  # remove the temp worktree and the LOCAL temp branch (the pushed copy on GitHub stays)
  g worktree remove --force "$WT" >/dev/null 2>&1 || true
  g worktree prune >/dev/null 2>&1 || true
  g branch -q -D "$BR" >/dev/null 2>&1 || true
}
trap cleanup EXIT
g worktree add -q -b "$BR" "$WT" origin/main
w() { git -C "$WT" "$@"; }
changes=()

render() { sed -e "s#__OWNER__#$OWNER#g" -e "s#__REF__#$REF#g" "$1"; }

managed_file() {  # $1 template, $2 destination (relative)
  local dst="$WT/$2" new; new="$(render "$1")"
  if [ ! -f "$dst" ]; then
    mkdir -p "$(dirname "$dst")"; printf '%s\n' "$new" > "$dst"; changes+=("add $2")
  elif grep -q "Managed by ido-pipeline" "$dst"; then
    if [ "$(cat "$dst")" != "$new" ]; then printf '%s\n' "$new" > "$dst"; changes+=("update $2"); fi
  else
    warn "$2 exists and isn't managed by ido-pipeline — left untouched"
  fi
}

managed_file "$TPL/workflows/pipeline.yml" ".github/workflows/pipeline.yml"
[ "$DEPLOY" = 1 ] && managed_file "$TPL/workflows/deploy.yml" ".github/workflows/deploy.yml"

if [ ! -f "$WT/.github/pull_request_template.md" ]; then
  mkdir -p "$WT/.github"; cp "$TPL/pull_request_template.md" "$WT/.github/pull_request_template.md"; changes+=("add PR template")
fi

if [ ! -f "$WT/.github/dependabot.yml" ]; then
  eco=()
  { [ -f "$WT/requirements.txt" ] || [ -f "$WT/pyproject.toml" ]; } && eco+=(pip)
  [ -f "$WT/package.json" ] && eco+=(npm)
  eco+=(github-actions)
  {
    echo "# Managed by ido-pipeline: weekly PRs that update outdated / vulnerable dependencies."
    echo "version: 2"; echo "updates:"
    for e in "${eco[@]}"; do
      printf '  - package-ecosystem: %s\n    directory: "/"\n    schedule: { interval: weekly }\n    open-pull-requests-limit: 5\n' "$e"
    done
  } > "$WT/.github/dependabot.yml"
  changes+=("add dependabot (${eco[*]})")
fi

# .gitignore — append missing safety lines only
touch "$WT/.gitignore"; added=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  grep -qxF "$line" "$WT/.gitignore" || { printf '%s\n' "$line" >> "$WT/.gitignore"; added=$((added+1)); }
done < "$TPL/gitignore"
[ "$added" -gt 0 ] && changes+=(".gitignore +$added safety rules")

# CLAUDE.md — insert or refresh the managed block
if python3 - "$WT/CLAUDE.md" "$TPL/CLAUDE-pipeline.md" <<'PY'; then changes+=("CLAUDE.md pipeline rules"); fi
import pathlib, re, sys
dst, blk = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]).read_text().strip() + "\n"
old = dst.read_text() if dst.exists() else ""
pat = re.compile(r"<!-- ido-pipeline:start -->.*?<!-- ido-pipeline:end -->\n?", re.S)
new = pat.sub(lambda _: blk, old) if pat.search(old) else (old.rstrip() + "\n\n" + blk if old.strip() else blk)
if new == old: sys.exit(1)
dst.write_text(new)
PY

# ------------------------------------------------------------------ 4. propose as a PR (or report in --check)
if [ ${#changes[@]} -eq 0 ]; then
  ok "$NAME already follows the pipeline standard ($REF) — nothing to change"
else
  echo "Changes for $NAME:"; printf '    %s\n' "${changes[@]}"
  if [ "$CHECK" = 1 ]; then
    w add -A; w --no-pager diff --cached --stat
    echo "(--check: nothing was changed)"
    exit 0
  fi
  w add -A
  w -c user.name="${GIT_AUTHOR_NAME:-$(git config user.name || echo ido-pipeline)}" \
    -c user.email="${GIT_AUTHOR_EMAIL:-$(git config user.email || echo pipeline@localhost)}" \
    -c commit.gpgsign=false commit -qm "chore: install ido-pipeline $REF" -m "$(printf '%s\n' "${changes[@]}")"
  w push -q -u origin "$BR"
  ok "pushed branch $BR"
  if [ "$OFFLINE" = 0 ]; then
    url="$(cd "$WT" && gh pr create --base main --head "$BR" --title "Install ido-pipeline ($REF)" \
      --body "$(printf 'Automated by onboard.sh:\n\n%s\n\nMerge to activate CI, security scans and Conflict Guard.\n' "$(printf -- '- %s\n' "${changes[@]}")")")"
    ok "Pull Request: $url"
  fi
fi

# ------------------------------------------------------------------ 5. repo settings + secrets (GitHub API; idempotent)
if [ "$OFFLINE" = 1 ] || [ "$CHECK" = 1 ]; then echo "Done."; exit 0; fi
REPO="$OWNER/$NAME"
gh api -X PATCH "repos/$REPO" -F delete_branch_on_merge=true -F allow_squash_merge=true \
  -F allow_merge_commit=false -F allow_rebase_merge=false -F allow_update_branch=true >/dev/null \
  && ok "settings: squash-merge only, auto-delete merged branches, 'Update branch' button"
gh api -X PUT "repos/$REPO/vulnerability-alerts" >/dev/null 2>&1 && ok "Dependabot alerts on"
gh api -X PUT "repos/$REPO/automated-security-fixes" >/dev/null 2>&1 && ok "Dependabot security-fix PRs on"

# Hard branch protection (works with GitHub Pro; on Free private repos GitHub refuses → pre-push hook still guards)
prot='{"required_status_checks":{"strict":true,"contexts":["ci / Secrets scan (gitleaks)","ci / Code quality + tests","ci / Security scan","conflicts / Conflict Guard"]},
"enforce_admins":false,"required_pull_request_reviews":null,"restrictions":null,"allow_force_pushes":false,"allow_deletions":false}'
if echo "$prot" | gh api -X PUT "repos/$REPO/branches/main/protection" --input - >/dev/null 2>&1; then
  ok "main is protected on GitHub: merge only when all checks are green"
else
  info "GitHub-side protection not available on this plan (needs GitHub Pro) — local pre-push guard is active"
fi

# Telegram alerts (shared by all repos): ~/.config/ido-pipeline/telegram.env
if [ -f "$CONF/telegram.env" ]; then
  # shellcheck disable=SC1091
  . "$CONF/telegram.env"
  [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && printf '%s' "$TELEGRAM_BOT_TOKEN" | gh secret set TELEGRAM_BOT_TOKEN -R "$REPO" >/dev/null
  [ -n "${TELEGRAM_CHAT_ID:-}" ]   && printf '%s' "$TELEGRAM_CHAT_ID"   | gh secret set TELEGRAM_CHAT_ID   -R "$REPO" >/dev/null
  ok "Telegram alerts connected"
else
  info "no $CONF/telegram.env — CI alerts won't go to Telegram (see README)"
fi

# Deploy secrets (asked once, never printed)
if [ "$DEPLOY" = 1 ]; then
  have="$(gh secret list -R "$REPO" 2>/dev/null | awk '{print $1}')"
  if echo "$have" | grep -qx DEPLOY_HOST; then ok "deploy secrets already set"
  elif [ "$YES" = 1 ]; then warn "deploy secrets missing — run onboard.sh --deploy without --yes to enter them"
  else
    read -r -p "Server IP/host: " h; read -r -p "SSH user [root]: " u; u="${u:-root}"
    read -r -p "App folder on the server (a git checkout of this repo): " p
    read -r -p "Restart command (e.g. pm2 restart $NAME): " rc
    read -r -p "Health-check URL (optional, Enter to skip): " hc
    kd="$(mktemp -d)"; ssh-keygen -q -t ed25519 -N "" -C "deploy-$NAME" -f "$kd/key"
    printf '%s' "$h"  | gh secret set DEPLOY_HOST -R "$REPO"
    printf '%s' "$u"  | gh secret set DEPLOY_USER -R "$REPO"
    printf '%s' "$p"  | gh secret set DEPLOY_PATH -R "$REPO"
    printf '%s' "$rc" | gh secret set RESTART_CMD -R "$REPO"
    [ -n "$hc" ] && printf '%s' "$hc" | gh secret set HEALTHCHECK_URL -R "$REPO"
    gh secret set DEPLOY_SSH_KEY -R "$REPO" < "$kd/key"
    echo; echo "Add this deploy key to the server (one time):"
    echo "  ssh $u@$h 'cat >> ~/.ssh/authorized_keys' < $kd/key.pub"
    if confirm "Run that now?"; then ssh "$u@$h" 'mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys' < "$kd/key.pub" && ok "deploy key installed"; fi
    rm -f "$kd/key"; ok "deploy secrets saved in GitHub"
  fi
fi
echo "Done. Merge the PR to switch the pipeline on."
