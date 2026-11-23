#!/usr/bin/env bash
# Builds the deploy bundle for one commit: taskdef.json + appspec.yaml at the zip root, which is
# what the pipeline's CodeDeployToECS action reads. The files are taken from git at that commit,
# so a rollback deploys the specs that belong to the image it rolls back to.
# Commits before deploy/taskdef.yaml existed have taskdef.json + appspec.yaml at the repo root.
#
# Usage: ./scripts/make-bundle.sh <commit> <out.zip>
# Uses yq and zip when installed (GitHub runners), otherwise Python with PyYAML.

# Stop on any error, unset variable or pipe failure.
set -euo pipefail

REF="${1:?usage: make-bundle.sh <commit> <out.zip>}"
OUT="${2:?usage: make-bundle.sh <commit> <out.zip>}"

# A Python that really runs (on Windows "python3" can be a Microsoft Store stub).
PY=""
for candidate in python3 python; do
  if "$candidate" -c 'import sys' >/dev/null 2>&1; then PY="$candidate"; break; fi
done

has_file() {
  git cat-file -e "$REF:$1" 2>/dev/null
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Task definition: convert YAML to JSON, or take the old JSON file as is.
if has_file deploy/taskdef.yaml; then
  git show "$REF:deploy/taskdef.yaml" > "$WORK/taskdef.yaml"
  if command -v yq >/dev/null 2>&1; then
    yq -o=json '.' "$WORK/taskdef.yaml" > "$WORK/taskdef.json"
  elif [[ -n "$PY" ]] && "$PY" -c 'import yaml' >/dev/null 2>&1; then
    "$PY" -c 'import json,sys,yaml; json.dump(yaml.safe_load(open(sys.argv[1])), open(sys.argv[2], "w"), indent=2)' \
      "$WORK/taskdef.yaml" "$WORK/taskdef.json"
  else
    echo "Need yq, or Python with PyYAML (pip install pyyaml), to convert taskdef.yaml" >&2
    exit 1
  fi
elif has_file taskdef.json; then
  git show "$REF:taskdef.json" > "$WORK/taskdef.json"
else
  echo "No deploy/taskdef.yaml or taskdef.json in $REF" >&2
  exit 1
fi

# AppSpec: deploy/ in new commits, repo root in old ones.
if has_file deploy/appspec.yaml; then
  git show "$REF:deploy/appspec.yaml" > "$WORK/appspec.yaml"
elif has_file appspec.yaml; then
  git show "$REF:appspec.yaml" > "$WORK/appspec.yaml"
else
  echo "No deploy/appspec.yaml or appspec.yaml in $REF" >&2
  exit 1
fi

rm -f "$OUT"
if command -v zip >/dev/null 2>&1; then
  zip -j -q "$OUT" "$WORK/taskdef.json" "$WORK/appspec.yaml"
elif [[ -n "$PY" ]]; then
  "$PY" -c 'import sys,zipfile,os; z=zipfile.ZipFile(sys.argv[1],"w",zipfile.ZIP_DEFLATED); [z.write(f, os.path.basename(f)) for f in sys.argv[2:]]; z.close()' \
    "$OUT" "$WORK/taskdef.json" "$WORK/appspec.yaml"
else
  echo "Need zip or Python to build the bundle" >&2
  exit 1
fi
