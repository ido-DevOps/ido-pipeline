<!-- ido-pipeline:start -->
## Git & CI rules (managed by ido-pipeline)
- Never commit or push to `main`. Work on a branch (`ido/<task>` on the Mac, `agent/<task>` on the server),
  push it, and open a PR with `gh pr create --base main --fill`. Ido merges PRs; you never do.
- Before starting: clean tree, `git switch main && git pull --ff-only`, then branch.
- CI runs on every push: secrets scan, lint/tests, security scan, Conflict Guard. Fix red checks before asking Ido to merge.
- Never hand-write or edit `.github/workflows/pipeline.yml` / `deploy.yml` here — they are generated.
  To (re)install the pipeline run: `bash ~/code/ido-pipeline/scripts/onboard.sh <repo-folder>`
  (on the Mac: the ido-pipeline folder path from repos.txt).
- Never commit secrets (.env, keys, tokens). If Conflict Guard reports a collision, ask Ido which version wins.
<!-- ido-pipeline:end -->
