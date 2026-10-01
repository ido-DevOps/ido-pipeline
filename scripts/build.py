#!/usr/bin/env python3
"""Embeds scripts/conflict_guard.py into .github/workflows/conflict-guard.yml.
Reusable workflows can't read files from this repo, so the script is inlined.
  python3 scripts/build.py          # update the workflow
  python3 scripts/build.py --check  # CI: fail if the workflow is out of date
"""
import pathlib, re, sys
root = pathlib.Path(__file__).resolve().parent.parent
src = (root / "scripts/conflict_guard.py").read_text()
wf_path = root / ".github/workflows/conflict-guard.yml"
wf = wf_path.read_text()
m = re.search(r"^( *)# >>> conflict_guard\.py\n.*?^ *# <<< conflict_guard\.py\n", wf, re.S | re.M)
if not m:
    sys.exit("markers not found in conflict-guard.yml")
ind = m.group(1)
body = "".join((ind + line if line.strip() else "\n") for line in src.splitlines(True))
if not body.endswith("\n"):
    body += "\n"
new = wf[:m.start()] + f"{ind}# >>> conflict_guard.py\n{body}{ind}# <<< conflict_guard.py\n" + wf[m.end():]
if "--check" in sys.argv:
    if new != wf:
        sys.exit("conflict-guard.yml is out of date — run: python3 scripts/build.py")
    print("conflict-guard.yml is up to date")
else:
    wf_path.write_text(new); print("conflict-guard.yml updated")
