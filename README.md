# ido-pipeline

One central repo that holds the CI/CD for **all** of Ido's projects. Each project has only a tiny
`pipeline.yml` that calls the workflows here, pinned to the `@v1` tag. Improve a check once here, release it,
and every project uses it on its next run.

## What every project gets
| On | What runs | Fails when |
|---|---|---|
| every push, every PR | **Secrets scan** (gitleaks, full history) | an API key/token/password is committed |
| every push, every PR | **Code quality + tests**: Python (ruff real-bug rules, pytest), Node (lint/test/build), ShellCheck | syntax errors, undefined names, failing tests, broken shell scripts |
| every push, every PR | **Security scan**: Semgrep (high severity), Bandit (high), pip-audit, npm audit (high) | dangerous code (injection, eval, shell=True…) or vulnerable dependencies |
| every PR + every merge to main | **Conflict Guard** | this PR changes the same lines as `main` or **another open PR** |
| weekly (Sunday) | full re-scan of main | new vulnerabilities published for your dependencies |
| merge to main (optional) | **Deploy** with health check and automatic rollback | restart/health check fails → previous version restored |
| weekly | **Dependabot** PRs for outdated or vulnerable packages and actions | — |
| any failure | **Telegram alert** with a link | — |

Repo settings applied by `onboard.sh`: squash-merge only (one clean commit per PR), merged branches
deleted automatically, an "Update branch" button, and Dependabot alerts and security fixes.

## Conflict Guard: "which version do you want?"
Git always detects two changes to the same line, but normally only at the moment you merge.
Conflict Guard checks in advance. It trial-merges, in a throw-away copy:
1. each open PR into `main`, and
2. **every pair** of open PRs (as if you merged #3 and then #5).

When two PRs touch the same lines, both PRs get:
- a red **Conflict Guard** check,
- a comment that shows the file, the line and **both versions side by side**, asking which one should win,
- the `merge-conflict` label, and
- a Telegram message.

Merge the version you want first. The other PR then needs its conflict resolved (you can tell the
assistant: *"tell Claude on the Mac: resolve the conflict in PR #5 in w-radar, keep the version from PR #3"* (mac-claude)).
After every merge to `main`, all open PRs are checked again and warnings are cleared automatically.
Changes to *different* lines merge cleanly and aren't flagged. CI runs on the merged result of each PR,
which catches the case where two PRs each work alone but break when combined.

## Why this won't wreck your repos
- **onboard.sh never touches `main` or your working folder.** It works in a temporary worktree, pushes a
  `pipeline/setup-...` branch and opens a PR. You merge it. The only exception is the first push of a
  brand-new, empty repo.
- It never force-pushes, never deletes remote branches, and never resets, rebases or stashes.
- It only updates files marked `Managed by ido-pipeline`. Hand-written files are left alone, with a warning.
- `--check` shows exactly what would change and changes nothing.
- **Conflict Guard is read-only**: all trial merges happen in a temporary worktree.
- **The tools are tested before they reach any project.** `self-test` runs ShellCheck, actionlint and 32
  scenario tests on throw-away repos. `release.sh` only moves `v1` to a commit where self-test passed.
  Rolling back is one command.
- A `pre-push` hook in every repo blocks direct pushes to `main`.
- GitHub can enforce "merge only when checks are green" itself, but on private repos that needs
  **GitHub Pro (~$4/month)**. `onboard.sh` turns it on automatically if your plan allows it.

## Setup (once)
```bash
cd ~/"עוזר ai"/ido-pipeline
bash scripts/bootstrap-central.sh        # private repo + access for your other repos + first v1 release
mkdir -p ~/.config/ido-pipeline && cat > ~/.config/ido-pipeline/telegram.env <<'X'
TELEGRAM_BOT_TOKEN=123456:ABC...           # same bot as the assistant
TELEGRAM_CHAT_ID=123456789                  # your chat id (message @userinfobot)
X
chmod 600 ~/.config/ido-pipeline/telegram.env
```

## Daily commands
```bash
bash scripts/onboard.sh ~/code/w-radar             # add/refresh the pipeline → opens a PR
bash scripts/onboard.sh ~/code/w-radar --deploy    # + auto-deploy (asks for server details once)
bash scripts/onboard.sh ~/code/new-idea            # brand-new folder → git init + private repo + pipeline
bash scripts/onboard.sh ~/code/w-radar --check     # dry run
bash scripts/onboard-all.sh ~/"עוזר ai"/repos.txt  # every project at once (one PR each)
python3 scripts/conflict_guard.py --local branch-a branch-b   # check two local branches yourself
```
From Telegram: *"/new-project w-radar"* or *"תוסיף את הפייפליין לפרויקט החדש"*. The assistant runs onboard.sh on the server.

## Changing the pipeline itself
1. Edit on a branch (`scripts/conflict_guard.py`, `.github/workflows/*.yml`, `templates/`).
   After editing `conflict_guard.py`, run `python3 scripts/build.py`.
2. Push and open a PR. self-test must be green. Merge.
3. Run `bash scripts/release.sh`. That moves `v1`, and every project uses the new version on its next run.
4. To roll back, run the command that `release.sh` prints.

For a breaking change, release it as `v2` (`release.sh v2`) and move projects over with `onboard.sh --ref v2`.

## Files
```
.github/workflows/ci.yml              reusable: secrets + quality/tests + security + alert
.github/workflows/conflict-guard.yml  reusable: Conflict Guard (script embedded by build.py)
.github/workflows/deploy.yml          reusable: SSH deploy + health check + rollback
.github/workflows/self-test.yml       tests this repo
scripts/onboard.sh                    install/refresh the pipeline in a project (safe, PR-based)
scripts/onboard-all.sh                onboard every repo in repos.txt
scripts/conflict_guard.py             the Conflict Guard logic (stdlib Python)
scripts/build.py · release.sh · bootstrap-central.sh
templates/                            files placed in each project
hooks/pre-push                        blocks direct pushes to main
tests/                                scenario tests (run: bash tests/test_onboard.sh)
```
