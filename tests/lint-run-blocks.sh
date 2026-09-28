#!/usr/bin/env bash
#
# Extracts every `run:` block from the workflows, replaces `${{ ... }}` with a
# placeholder and checks each block with `bash -n` and shellcheck. Bash inside
# YAML is otherwise parsed by nothing until it runs on GitHub.
#
# Usage: bash tests/lint-run-blocks.sh [workflow files...]
# Requires python3 with PyYAML, and shellcheck.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
out_dir="$(mktemp -d)"
trap 'rm -rf "$out_dir"' EXIT

if [ "$#" -eq 0 ]; then
    set -- "$repo_root"/workflows/*.yml "$repo_root"/.github/workflows/*.yml
fi

python3 - "$out_dir" "$@" <<'PY'
import os
import re
import sys

import yaml

out_dir, files = sys.argv[1], sys.argv[2:]
count = 0
for path in files:
    with open(path) as handle:
        workflow = yaml.safe_load(handle)
    for job_name, job in (workflow.get("jobs") or {}).items():
        for index, step in enumerate(job.get("steps") or []):
            script = step.get("run")
            if script is None:
                continue
            shell = step.get("shell", "bash")
            if shell != "bash":
                continue
            script = re.sub(r"\$\{\{.*?\}\}", "GHA_EXPR", script, flags=re.S)
            name = step.get("name") or step.get("id") or f"step-{index}"
            slug = re.sub(r"[^A-Za-z0-9]+", "-", f"{os.path.basename(path)}-{job_name}-{index}-{name}")
            with open(os.path.join(out_dir, slug + ".sh"), "w") as target:
                target.write("#!/usr/bin/env bash\n# shellcheck shell=bash\nset -eo pipefail\n")
                target.write(script)
            count += 1
print(f"extracted {count} run blocks from {len(files)} workflow files")
PY

status=0
for block in "$out_dir"/*.sh; do
    if ! bash -n "$block"; then
        echo "SYNTAX ERROR  $(basename "$block")"
        status=1
    elif ! shellcheck --severity=style "$block"; then
        echo "SHELLCHECK    $(basename "$block")"
        status=1
    else
        echo "ok            $(basename "$block")"
    fi
done
exit "$status"
